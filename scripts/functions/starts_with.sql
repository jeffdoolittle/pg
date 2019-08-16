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
