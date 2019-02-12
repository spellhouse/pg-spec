(ns pg-spec.derive
  "Generate Clojure specs for a PostgreSQL database."
  (:require
   [clojure.spec.alpha :as s]
   [clojure.java.io :as jio]
   [clojure.java.jdbc :as jdbc])
  (:import
   (clojure.lang ISeq)
   (org.postgresql.jdbc PgArray)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------
;; Database

(extend-type org.postgresql.jdbc.PgArray
  jdbc/IResultSetReadColumn
  (result-set-read-column [pg-array _2 _3]
    (vec (.getArray pg-array))))

(def pg-introspection-query
  (delay (slurp (clojure.java.io/resource "columns.sql"))))

(defn pg-introspect
  [db]
  (jdbc/query db [(deref pg-introspection-query)]))

;; ---------------------------------------------------------------------
;; Spec derivation

(def
  ^{:doc "The current root namespace for all generated specs."
    :dynamic true}
  *root-ns*
  'db)

(defn pred-form [column-info]
  (let [base-data-type (get column-info :base_data_type)]
    (if (string? base-data-type)
      (cond
        (re-matches #"\A(?:character(?: varying)?|text)\z" base-data-type)
        (if-some [max-length (get column-info :character_maximum_length)]
          (list 's/with-gen
                'string?
                (list 'fn []
                      (list 's.gen/fmap 'clojure.string/join
                            (list 's.gen/vector '(s.gen/char-ascii) 0 max-length))))
          'string?)

        (re-matches #"\A(?:date|timestamp with(?:out)? time zone\z)" base-data-type)
        'inst?

        (re-matches #"\A(?:double precision|numeric(?:\(\d+,\d+\))?|real)?\z"
                    base-data-type)
        'float?

        (re-matches #"\Ajsonb?\z" base-data-type)
        '(s/or :json-object map?
               :json-array sequential?
               :json-number number?
               :json-string string?
               :json-boolean boolean?
               :json-null nil?)

        :else
        (case base-data-type
          "array" (let [data-type (get column-info :data_type)
                        [_ data-type*] (re-matches #"\A(.+)\[\]\z" data-type)
                        column-info* (assoc column-info
                                            :base_data_type data-type*
                                            :data_type data-type*)]
                    (list 's/coll-of (pred-form column-info*) :kind 'sequential?))
          "boolean" 'boolean?
          "bytea" 'bytes?
          "bigint" 'integer?
          ("public.hstore" "hstore") '(s/map-of string? (s/nilable string?))
          "integer" 'integer?
          "smallint" 'int?
          "uuid" 'uuid?
          "enum" (apply sorted-set (get column-info :allowed))
          ;; else
          (throw (ex-info (str "Unhandled base-data-type: " (pr-str base-data-type))
                          column-info)))) 
      ::s/unknown)))

(defn spec-key [column-info]
  (keyword (str (name *root-ns*) "." (get column-info :table_name))
           (get column-info :column_name)))

(defn spec-form [column-info]
  (if (get column-info :is_nullable)
    (list 's/nilable (pred-form column-info))
    (pred-form column-info)))

(defn relevant-table? [column-info]
  (not (.startsWith ^String (get column-info :table_name "") "_")))

(defn relevant-schema? [column-info]
  (= (get column-info :table_schema) "public"))

(defn spec-def [column-info]
  (list 's/def (spec-key column-info) (spec-form column-info)))

(defn print-spec [column-info]
  (let [spec-key (spec-key column-info)
        spec-form (spec-form column-info)]
    (print "(s/def" spec-key)
    (if (and (seq? spec-form)
             (= (first spec-form) 's/or))
      (do
        (println)
        (let [tags+specs (partition 2 (rest spec-form))]
          (when-some [[tf sf] (first tags+specs)]
            (printf "  (s/or %s %s\n" tf sf))
          (run!
           (fn [[t s]]
             (printf "        %s %s\n" t s))
           (rest (butlast tags+specs)))
          (if-some [[tl sl] (last tags+specs)]
            (printf "        %s %s))\n" tl sl)
            (println "))")))
        (println))
      (printf " %s)\n" spec-form))))

(defn table-spec-key [column-info]
  (keyword (name *root-ns*) (get column-info :table_name)))

(defn print-specs
  ([db]
   (println "(ns" *root-ns*)
   (println "  (:require [clojure.spec.alpha :as s]")
   (println "            [clojure.spec.gen.alpha :as s.gen]))")
   (println)
   (run!
    (fn [[table-name table-column-info]]
      (let [table-column-info (sort-by :column_name table-column-info)]
        (println ";; ---------------------------------------------------------------------")
        (printf ";; %s\n" table-name)
        (println)
        (run! print-spec table-column-info)
        (printf "(s/def %s\n" (keyword (name *root-ns*) table-name))
        (let [spec-keys (map spec-key table-column-info)]
          (printf "  (s/keys :opt-un [%s\n" (first spec-keys))
          (run!
           (fn [k]
             (printf "                   %s\n" k))
           (rest (butlast spec-keys)))
          (if-some [last-key (last spec-keys)]
            (printf "                   %s]))\n" last-key)
            (println "]))")))
        (println)))
    (sort-by key
             (group-by :table_name
                       (sequence
                        (comp (filter relevant-schema?)
                              (filter relevant-table?))
                        (pg-introspect db)))))))
