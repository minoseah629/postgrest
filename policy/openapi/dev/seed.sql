-- Example schema for linting PostgREST's generated OpenAPI spec.
-- varchar(n) makes PostgREST emit maxLength; plain text would not.
create schema api;

create table api.todos (
  id   uuid primary key default gen_random_uuid(),
  task varchar(200) not null,
  done boolean not null default false
);

create role anon nologin;
grant usage on schema api to anon;
grant select on api.todos to anon;

-- Writes require a JWT whose role claim is "todo_user".
create role todo_user nologin;
grant usage on schema api to todo_user;
grant select, insert, update, delete on api.todos to todo_user;

create role authenticator noinherit login password 'pass';
grant anon, todo_user to authenticator;
