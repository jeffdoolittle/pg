set client_min_messages TO WARNING;
drop schema if exists velzy cascade;
create schema if not exists velzy;
set search_path=velzy;
drop function if exists create_collection(varchar);
create function create_collection(
	collection varchar,
	out res jsonb
)
as $$
declare
	schema varchar := 'velzy';
begin
	res := '{"created": false, "message": null}';
	-- see if table exists first
  if not exists (select 1 from information_schema.tables where table_schema = schema AND table_name = collection) then

		execute format('create table %s.%s(
            id bigserial primary key not null,
            body jsonb not null,
            search tsvector,
            created_at timestamptz not null default now(),
            updated_at timestamptz not null default now()
          );',schema,collection);

		--indexing
    execute format('create index idx_search_%s on %s.%s using GIN(search)',collection,schema,collection);
    execute format('create index idx_json_%s on %s.%s using GIN(body jsonb_path_ops)',collection,schema,collection);

		execute format('create trigger %s_notify_change AFTER INSERT OR UPDATE OR DELETE ON %s.%s
		FOR EACH ROW EXECUTE PROCEDURE velzy.notify_change();', collection, schema, collection);

    res := '{"created": true, "message": "Table created"}';

    perform pg_notify('velzy.change',concat(collection, ':table_created:',0));
  else
    res := '{"created": false, "message": "Table exists"}';
    raise debug 'This table already exists';

  end if;

end;
$$
language plpgsql;
set search_path=velzy;

drop function if exists create_lookup_column(varchar,varchar, varchar);
create function create_lookup_column(collection varchar, schema varchar, key varchar, out res bool)
as $$
declare
	column_exists int;
  lookup_key varchar := 'lookup_' || key;
begin
		execute format('SELECT count(1)
										FROM information_schema.columns
										WHERE table_name=%L and table_schema=%L and column_name=%L',
									collection,schema,lookup_key) into column_exists;

		if column_exists < 1 then
			-- add the column
			execute format('alter table %s.%s add column %s text', schema, collection, lookup_key);

			-- fill it
			execute format('update %s.%s set %s = body ->> %L', schema, collection, lookup_key, key);

			-- index it
			execute format('create index on %s.%s(%s)', schema, collection, lookup_key);

      -- TODO: drop a trigger on this!
      execute format('CREATE TRIGGER trigger_update_%s_%s
      after update on %s.%s
      for each row
      when (old.body <> new.body)
      execute procedure velzy.update_lookup();'
      ,collection, lookup_key, schema, collection);
		end if;
		res := true;
end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists delete(varchar,int);
create function delete(collection varchar, id int, out res bool)
as $$

begin
		execute format('delete from velzy.%s where id=%s returning *',collection, id);
		res := true;
end;

$$ language plpgsql;
set search_path=velzy;
drop function if exists drop_lookup_columns(varchar, varchar);
create function drop_lookup_columns(
	collection varchar,
	schema varchar default 'velzy',
	out res bool
)
as $$
declare lookup text;
begin
		for lookup in execute format('SELECT column_name
										FROM information_schema.columns
										WHERE table_name=%L AND table_schema=%L AND column_name LIKE %L',
									collection,schema,'lookup%') loop
			execute format('alter table %s.%s drop column %I', schema, collection, lookup);
		end loop;

		res := true;
end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists ends_with(varchar, varchar, varchar, varchar);
create function ends_with(
	collection varchar,
	key varchar,
	term varchar,
	schema varchar default 'velzy'
)
returns setof jsonb
as $$
declare
	search_param text := '%' || term;
  query_text text := format('select body from %s.%s where %s ilike %L',schema,collection,'lookup_' || key,search_param);
begin

	-- ensure we have the lookup column created if it doesn't already exist
	perform velzy.create_lookup_column(collection => collection, schema => schema, key => key);

	return query
	execute query_text;
end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists "exists"(varchar, text,varchar);
create function "exists"(
	collection varchar,
	term text,
	schema varchar default 'velzy'
)
returns setof jsonb
as $$
declare
	existence bool := false;
begin
	return query
	execute format('
		select body from %s.%s
		where body ? %L;
',schema,collection, term);

end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists find(varchar, jsonb,varchar);
create function find(
	collection varchar,
	term jsonb,
	schema varchar default 'velzy'
)
returns setof jsonb
as $$
begin
	return query
	execute format('
		select id, body from %s.%s
		where body @> %L;
',schema,collection, term);

end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists find_one(varchar, jsonb,varchar);
create function find_one(
	collection varchar,
	term jsonb,
	schema varchar default 'velzy',
	out res jsonb
)
as $$
begin

	execute format('
		select body from %s.%s
		where body @> %L limit 1;
',schema,collection, term) into res;

end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists fuzzy(varchar, varchar, varchar,varchar);
create function fuzzy(
	collection varchar,
	key varchar,
	term varchar,
	schema varchar default 'velzy'
)
returns setof jsonb
as $$
begin
	return query
	execute format('
	select body from %s.%s
	where body ->> %L ~* %L;
',schema,collection, key, term);

end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists get(varchar,int);
create function get(collection varchar, id int, out res jsonb)
as $$

begin
		execute format('select body from velzy.%s where id=%s',collection, id) into res;
end;

$$ language plpgsql;
set search_path=velzy;
drop function if exists modify(varchar, int, jsonb, varchar);
create function modify(
	collection varchar,
	id int,
	set jsonb,
	schema varchar default 'velzy',
	out res jsonb
)
as $$

begin
	-- join it
	execute format('select body || %L from %s.%s where id=%s', set,schema,collection, id) into res;

	-- save it - this will also update the search
	perform velzy.save(collection => collection, schema => schema, doc => res);

  --notification
  perform pg_notify('velzy',concat(collection, ':update:',saved.id));
end;

$$ language plpgsql;
	set search_path=velzy;
	CREATE FUNCTION notify_change()
	RETURNS trigger as $$
	BEGIN
    if(TG_OP = 'UPDATE' and (OLD.body IS NOT DISTINCT from NEW.body)) THEN
      --ignore this because it's a search field setting from the save function
      --and we don't want it to fire
    ELSIF(TG_OP = 'DELETE') THEN
      -- don't return any kind of ID
      perform(select pg_notify('velzy.change',concat(TG_TABLE_NAME,':DELETE:',OLD.id)));
    ELSE
		  perform(select pg_notify('velzy.change',concat(TG_TABLE_NAME,':',TG_OP,':',NEW.id)));
    END IF;
		RETURN NULL;
	END;
  $$ LANGUAGE plpgsql;
set search_path=velzy;
drop function if exists save(text, jsonb,text[],text);
create function save(
	collection text,
	doc jsonb,
	search text[] = array['name','email','first','first_name','last','last_name','description','title','city','state','address','street', 'company'],
	schema text default 'velzy',
	out res jsonb
)
as $$

declare
	doc_id int := doc -> 'id';
  next_key bigint;
	saved record;
	saved_doc jsonb;
	search_key text;
	search_params text;
  search_term text;
begin
	-- make sure the table exists
	perform velzy.create_collection(collection => collection);

	if (select doc ? 'id') then

		execute format('insert into %s.%s (id, body)
										values (%L, %L)
										on conflict (id)
										do update set body = excluded.body
										returning *',schema,collection, doc -> 'id', doc) into saved;
    res := saved.body;

	else

    --this is dumb, but I need to make sure the key is merged
    --nextval is transactional so it won't be repeated
    --this is so hacky... Craig... HELP>>>
    next_key := nextval(pg_get_serial_sequence(concat(schema,'.', collection), 'id'));

    --merge the new id into the JSON
    select(doc || format('{"id": %s}', next_key::text)::jsonb) into res;

    --save it, making sure the new id is also the actual id :)
		execute format('insert into %s.%s (id, body) values (%s, %L) returning *', schema,collection, next_key, res) into saved;

	end if;


	-- do it automatically MMMMMKKK?
	foreach search_key in array search
	loop
		if(res ? search_key) then
      search_term := (res ->> search_key);

      --reset spurious characters and domains to increase search effectiveness
      search_term := replace(search_term, '@',' ');
      search_term := replace(search_term, '.com',' ');
      search_term := replace(search_term, '.net',' ');
      search_term := replace(search_term, '.org',' ');
      search_term := replace(search_term, '.edu',' ');

			search_params :=  concat(search_params,' ', search_term);
		end if;
	end loop;
	if search_params is not null then
		execute format('update %s.%s set search=to_tsvector(%L) where id=%s',schema,collection,search_params,saved.id);
	end if;

  --update the updated_at bits no matter what
  execute format('update %s.%s set updated_at = now() where id=%s',schema,collection, saved.id);

end;

$$ language plpgsql;
set search_path=velzy;
create function search(collection varchar, term varchar, schema varchar default 'velzy')
returns table(
	result jsonb,
	rank float4
)
as $$
declare
begin
	return query
	execute format('select body, ts_rank_cd(search,plainto_tsquery(''"%s"'')) as rank
									from %s.%s
									where search @@ plainto_tsquery(''"%s"'')
									order by ts_rank_cd(search,plainto_tsquery(''"%s"'')) desc'
			,term, schema,collection,term, term);
end;

$$ language plpgsql;
set search_path=velzy;
drop function if exists starts_with(varchar, varchar, varchar, varchar);
create function starts_with(
	collection varchar,
	key varchar,
	term varchar,
	schema varchar default 'velzy'
)
returns setof jsonb
as $$
declare
	search_param text := term || '%';
begin

	-- ensure we have the lookup column created if it doesn't already exist
	perform velzy.create_lookup_column(collection => collection, schema => schema, key => key);

	return query
	execute format('select body from %s.%s where %s ilike %L',schema,collection,'lookup_' || key,search_param);
end;
$$ language plpgsql;
set search_path=velzy;
drop function if exists table_list();
create function table_list()
returns table(
	table_name text,
	row_count int
)
as $$
begin
	return query execute format('
	SELECT relname::text as name,n_live_tup::int as rows
  FROM pg_stat_user_tables
	where schemaname=%s',
		'''velzy''');

end;
$$ language plpgsql;
set search_path=velzy;

drop function if exists update_lookup();
create function update_lookup()
returns trigger 
as $$
declare
  lookup_key text;
	json_key text;
begin
	
	for lookup_key in (select column_name from information_schema.columns
										where table_name=TG_TABLE_NAME and table_schema=TG_TABLE_SCHEMA 
										and column_name like 'lookup_%')
	loop 
		json_key := split_part(lookup_key,'_',2);

    execute format('update %s.%s set %s = %L where id=%s',
                    TG_TABLE_SCHEMA, 
                    TG_TABLE_NAME, 
                    lookup_key, new.body ->> json_key, 
                    new.id
                  );
  end loop;
  return new;
end;
$$ language plpgsql;
