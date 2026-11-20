-- Fixture for `postgrest-with-pg-XX --fixtures ...` (used by scripts/lint-built.sh).
-- The wrapper already creates the authenticator role named in :PGUSER, so this
-- variant of seed.sql only creates the schema, table and the other roles.
create schema api;

create table api.todos (
  id   uuid primary key default gen_random_uuid(),
  task varchar(200) not null,
  done boolean not null default false
);

create role anon nologin;
grant usage on schema api to anon;
grant select on api.todos to anon;

create role todo_user nologin;
grant usage on schema api to todo_user;
grant select, insert, update, delete on api.todos to todo_user;

grant anon, todo_user to :"PGUSER";
