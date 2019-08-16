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
