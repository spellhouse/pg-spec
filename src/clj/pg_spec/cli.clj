(ns pg-spec.cli
  (:require
   [pg-spec.derive]
   [clojure.spec.alpha :as s]
   [clojure.tools.cli :as cli]
   [meander.match.alpha :as r.match]))

(def partial-db-spec
  "A partial clojure.java.jdbc db map to be completed with option data
  parsed from a command line."
  {:dbtype "postgresql"
   :dbname ""
   :host ""
   :user ""
   :password ""
   :ssl false
   :sslfactory "org.postgresql.ssl.NonValidatingFactory"})

(def option-specs
  "option-specs for clojure.tools.cli/parse-opts."
  [[nil "--dbname DBNAME" "Database name"]
   ["-h" "--host HOST" "Host name of the machine on which PostgreSQL is running."
    :default "localhost"] 
   ["-u" "--user USER" "User to connect to the database as instead of the default."
    :default (get (System/getenv) "USER")]
   ["-p" "--password PASSWORD" "User password to authenticate with."
    :default ""]
   [nil "--root-ns NS" "The root namespace for which all emitted specs will based on"
    :default "db"]
   [nil "--help" "Show help"]])

(defn parse-cli-args
  "Parse command line arguments"
  [cli-args]
  (let [parse-data (cli/parse-opts cli-args option-specs)
        extra-errors (r.match/search cli-args
                       [(not "--dbname") ...]
                       "Missing required option \"--dbname\""

                       [(not "--user") ...]
                       "Missing required option \"--user\"")]
    (update parse-data :errors (fnil into []) extra-errors)))

(defn -main
  [& cli-args]
  (r.match/find (parse-cli-args cli-args)
    {:errors (pred not-empty ?errors)}
    (do (run! println ?errors)
        (System/exit 1))

    {:options {:help true}
     :summary ?summary}
    (println ?summary)

    {:options (and ?options {:root-ns ?root-ns})}
    (binding [pg-spec.derive/*root-ns* ?root-ns]
      (pg-spec.derive/print-specs (merge partial-db-spec ?options)))))
