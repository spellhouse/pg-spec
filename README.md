# pg-spec

`pg-spec` is a `clojure` command line utility for deriving Clojure
specs from a Postgres database.

## Usage

The simplest way to use `pg-spec` is to place the following script
on your `PATH` and make it executable.

```sh
#!/usr/bin/env bash
clojure -Sdeps '{:deps {spellhouse/pg-spec {:git/url "https://github.com/spellhouse/pg-spec" :sha "07f8797816c5d49fc2d4e721a01fb8f7beb4f4f1"}}}' \
        -m pg-spec.cli $@
```

Assuming the file was named `pg-spec` you can now execute the command

```
pg-spec --help
```

which should print out

```
      --dbname DBNAME                 Database name
  -h, --host HOST          localhost  Host name of the machine on which PostgreSQL is running.
  -u, --user USER          noprompt   User to connect to the database as instead of the default.
  -p, --password PASSWORD             User password to authenticate with.
      --root-ns NS         db         The root namespace for which all emitted specs will based on
      --help                          Show help
```
