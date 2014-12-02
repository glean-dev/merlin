open Std

type digest = Digest.t
let section = Logger.section "indexer"

let file_mtime path =
  try (Unix.stat path).Unix.st_mtime
  with Unix.Unix_error _ -> nan

type cmi = {
  name: string;
  path: string;
  mtime: float;
  digest: digest;
  deps: digest list;
}

let get_cmi path =
  let open Cmi_format in
  let mtime = (Unix.stat path).Unix.st_mtime in
  let cmi = read_cmi path in
  let name = cmi.cmi_name in
  let rec deps mydigest acc = function
    | [] -> mydigest, List.rev acc
    | (_, None) :: xs ->
      deps mydigest acc xs
    | (name', Some mydigest) :: xs when name = name' ->
      deps mydigest acc xs
    | (_, Some digest) :: xs ->
      deps mydigest (digest :: acc) xs
  in
  let digest, deps = deps "" [] cmi.cmi_crcs in
  if digest = "" then
    raise Not_found
  else
    { name; path; mtime; digest; deps }

type db = {
  path_index: (string, cmi) Hashtbl.t;
  digest_index: (Digest.t, cmi) Hashtbl.t;
  back_deps: (Digest.t, Digest.t list) Hashtbl.t;

  mutable remlist: cmi list;
  mutable addlist: cmi list;
}

let fresh () = {
  path_index = Hashtbl.create 7;
  digest_index = Hashtbl.create 7;
  back_deps = Hashtbl.create 7;
  remlist = [];
  addlist = [];
}

let json_of_digest digest = `String (Digest.to_hex digest)

let rem db digest =
  Logger.infojf section ~title:"rem digest" json_of_digest digest;
  try
    let info = Hashtbl.find db.digest_index digest in
    Hashtbl.remove db.digest_index digest;
    assert (Hashtbl.find db.path_index info.path == info);
    Hashtbl.remove db.path_index info.path;
    db.remlist <- info :: db.remlist
  with Not_found -> ()

let add db info =
  Logger.infojf section ~title:"add info"
    (fun {name; path; mtime; digest; deps} ->
       `Assoc [
         "name", `String name;
         "path", `String path;
         "mtime", `Float mtime;
         "digest", json_of_digest digest;
         "deps", `List (List.map json_of_digest deps)
       ]) info;
  let skip =
    try
      let info' = Hashtbl.find db.path_index info.path in
      if info.digest = info'.digest then
        true
      else
        (rem db info'.digest; false)
    with Not_found -> false
  in
  if skip then ()
  else
    begin
      Hashtbl.replace db.path_index info.path info;
      Hashtbl.replace db.digest_index info.digest info;
      db.addlist <- info :: db.addlist
    end

let compact db =
  let to_remove = Hashtbl.create 7 in
  let to_update = Hashtbl.create 7 in
  let remember tbl v digest = Hashtbl.replace tbl digest v in
  let not_in tbl v = not (Hashtbl.mem tbl v) in
  let rem_info info =
    if Hashtbl.mem db.digest_index info.digest then ()
    else begin
      remember to_remove () info.digest;
      List.iter (remember to_update []) info.deps
    end
  and add_info info =
    let update_dep digest =
      let existing =
        try Hashtbl.find to_update digest
        with Not_found -> [] in
      Hashtbl.replace to_update digest (info.digest :: existing)
    in
    if not (Hashtbl.mem to_remove info.digest) then
      List.iter update_dep info.deps
  in
  List.iter rem_info db.remlist;
  List.iter add_info db.addlist;
  db.remlist <- [];
  db.addlist <- [];
  let update_back digest deps =
    let digests =
      try Hashtbl.find db.back_deps digest
      with Not_found -> []
    in
    let digests = List.filter (not_in to_remove) digests in
    let digests = deps @ digests in
    if digests = [] then
      begin
        Logger.infojf section ~title:"remove backdeps" json_of_digest digest;
        Hashtbl.remove db.back_deps digest
      end
    else
      begin
        Logger.infojf section ~title:"update backdeps"
          (fun (digest, digests) ->
                `Assoc [
                  "digest", json_of_digest digest;
                  "rdeps", `List (List.map json_of_digest digests)
               ]) (digest, digests);
        Hashtbl.replace db.back_deps digest digests
      end
  in
  Hashtbl.iter update_back to_update;
  Logger.info section ~title:"compact" "done"

let compact = function
  | { addlist = []; remlist = [] } ->
    Logger.info section ~title:"compact" "nothing to do";
  | db ->
    Logger.info section ~title:"compact" "starting compaction";
    compact db

let outdated db =
  let is_old info = file_mtime info.path <> info.mtime in
  Hashtbl.fold
    (fun _ info olds -> if is_old info then info.digest :: olds else olds)
    db.digest_index []

let updated db paths =
  let is_new path = file_mtime path <>
                    (try (Hashtbl.find db.path_index path).mtime
                     with Not_found -> nan)
  in
  let refresh path =
    if is_new path then
      try Some (get_cmi path)
      with Not_found ->
        Logger.errorj section ~title:"updated" (`String path);
        None
    else
      None
  in
  List.filter_map refresh paths

let update_cmis db paths =
  List.iter (rem db) (outdated db);
  List.iter (add db) (updated db paths);
  compact db

let update_path db paths =
  let expand_path path =
    try
      let files = Array.to_list (Sys.readdir path) in
      let is_cmi fn = Filename.check_suffix fn ".cmi" in
      let files = List.filter is_cmi files in
      match List.map ~f:(Filename.concat path) files with
      | [] -> None
      | files -> Some files
    with _exn ->
      Logger.errorj section ~title:"expand_path" (`String path);
      None
  in
  let paths = List.Lazy.filter_map ~f:expand_path paths in
  let paths = List.Lazy.to_strict paths in
  let paths = List.concat paths in
  update_cmis db paths

let rdeps db digest =
  compact db;
  try Hashtbl.find db.back_deps digest
  with Not_found -> []

let find_digest db digest =
  compact db;
  Hashtbl.find db.digest_index digest

let find_path db path =
  compact db;
  Hashtbl.find db.path_index path
