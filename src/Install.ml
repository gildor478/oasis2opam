(***************************************************************************)
(*  OASIS2OPAM: Convert OASIS metadata to OPAM package descriptions        *)
(*                                                                         *)
(*  Copyright (C) 2013-2015, Christophe Troestler                          *)
(*                                                                         *)
(*  This library is free software; you can redistribute it and/or modify   *)
(*  it under the terms of the GNU General Public License as published by   *)
(*  the Free Software Foundation; either version 3 of the License, or (at  *)
(*  your option) any later version, with the OCaml static compilation      *)
(*  exception.                                                             *)
(*                                                                         *)
(*  This library is distributed in the hope that it will be useful, but    *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file      *)
(*  COPYING for more details.                                              *)
(*                                                                         *)
(*  You should have received a copy of the GNU Lesser General Public       *)
(*  License along with this library; if not, write to the Free Software    *)
(*  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301   *)
(*  USA.                                                                   *)
(***************************************************************************)

(** Functions to write a <pkg>.install file. *)

(* FIXME: This code is extremely naive.  This functionality should be
   in an oasis plugin.  Until then, we can live with this... *)

open Format
open OASISTypes
open Utils

let binaries t ~flags =
  let gather_exec bins = function
    | Executable(cs, bs, es) ->
       if eval_conditional flags bs.bs_install then (
         (* Binary that will be installed *)
         let path = Filename.concat "_build" bs.bs_path in
         let exec = try Filename.chop_extension es.exec_main_is
                    with _ -> es.exec_main_is in
         let exec = Filename.concat path exec in
         (exec, cs.cs_name) :: bins
       )
       else bins
    | _ -> bins (* skip other sections *) in
  List.fold_left gather_exec [] (Tarball.oasis t).sections

(* (Subset of) Possible locations for OPAM. *)
type dest_dir = Lib | Libexec | Bin | Sbin | Share | Etc | Doc | Man

let all_dest_dirs = [Lib; Libexec; Bin; Sbin; Share; Etc; Doc; Man]

let string_of_dest_dir = function
  | Lib -> "lib"
  | Libexec -> "libexec"
  | Bin -> "bin"
  | Sbin -> "sbin"
  | Share -> "share"
  | Etc -> "etc"
  | Doc -> "doc"
  | Man -> "man"

let default_dest =
  (Share, "") (* the second component is the relative path *)

let split_slash d =
  try let i = String.index d '/' in
      (String.sub d 0 i, String.sub d (i + 1) (String.length d - i - 1))
  with Not_found -> (d, "")

let classify_dest d =
  let dest, dir = split_slash d in
  if dest = "$libdir" then (Lib, dir)
  else if dest = "$libexecdir" then (Libexec, dir)
  else if dest = "$bindir" then (Bin, dir)
  else if dest = "$sbindir" then (Sbin, dir)
  else if dest = "$datadir" then (Share, dir)
  else if dest = "$sysconfdir" then (Etc, snd(split_slash dir))
                                      (* $sysconfdir/pkg/dir *)
  else if dest = "$docdir" then (Doc, dir)
  else if dest = "$mandir" then (Man, dir)
  else (
    warn(sprintf "Target %S not recognized, installing in share/" dest);
    default_dest
  )

let classify_dest_opt = function
  | Some dest -> classify_dest dest
  | None -> default_dest

let output_classified ppf (local, (_, dir)) =
  if dir = "" then fprintf ppf "@\n%S" local
  else let dest = Filename.concat dir (Filename.basename local) in
       fprintf ppf "@\n%S {%S}" local dest

(* Gather all DataFiles. *)
let datafiles t ~flags =
  let pkg = Tarball.oasis t in
  let gather_data_files datas = function
    | Library(_, bs, _)
    | Object(_, bs, _)
    | Executable(_, bs, _) ->
       if eval_conditional flags bs.bs_install then (
         let d = bs.bs_data_files in
         let d = List.map (fun (f, l) -> (Filename.concat bs.bs_path f,
                                        classify_dest_opt l)) d in
         d @ datas
       )
       else datas
    | _ -> datas (* skip other sections *) in
  List.fold_left gather_data_files [] pkg.sections


let write_bin ppf bins data_bin =
  if bins <> [] || data_bin <> [] then (
    fprintf ppf "@[<2>bin: [";
    let output_bin (exec, name) =
      let exec = Utils.escaped exec in
      let name = Utils.escaped name in
      fprintf ppf "@\n\"?%s.byte\" {\"%s\"}" exec name;
      fprintf ppf "@\n\"?%s.native\" {\"%s\"}" exec name;
    in
    List.iter output_bin bins;
    List.iter (output_classified ppf) data_bin;
    fprintf ppf "@]@\n]@\n"
  )

let write_datas ppf datas =
  let write_dest dest_dir =
    let datas = List.filter (fun (_, (d, _)) -> d = dest_dir) datas in
    if datas <> [] then (
      fprintf ppf "@[<2>%s: [" (string_of_dest_dir dest_dir);
      List.iter (output_classified ppf) datas;
      fprintf ppf "@]@\n]@\n"
    ) in
  List.iter write_dest all_dest_dirs

let opam t ~local flags =
  let pkg = Tarball.oasis t in
  let bins = binaries t ~flags in
  let datas = datafiles t ~flags in
  let data_bin, datas = List.partition (fun (_, (d, _)) -> d = Bin) datas in
  if bins <> [] || datas <> [] then (
    let fname = pkg.name ^ ".install" in
    if local then
      (* In local mode, the goal is to generate the opam files in
         the repository itself. *)
      let fh = open_out fname in
      let ppf = Format.formatter_of_out_channel fh in
      write_bin ppf bins data_bin;
      write_datas ppf datas;
      close_out fh
    else (
      let buf = Buffer.create 1024 in
      let ppf = Format.formatter_of_buffer buf in
      write_bin ppf bins data_bin;
      write_datas ppf datas;
      let contents = Buffer.contents buf in
      match Tarball.install t with
      | Some install ->
         (* FIXME: more clever comparison is desirable. *)
         if String.trim install <> String.trim contents then
           warn(sprintf "A %s file was found in the tarball but its \
                         content differs from the generated one. Make sure \
                         it is compatible with:\n%s" fname contents)
      | None ->
         let dir = Filename.concat (Tarball.pkg_opam_dir t) "files" in
         let full_fname = Filename.concat dir fname in
         warn(sprintf "No %s file was found at the root of the tarball, \
                       so creating %s. Its is recommended to add \
                       it to your repository though (\"oasis2opam --local\" \
                       may help)." fname full_fname);
         (try Unix.mkdir dir 0o777
          with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
         let fh = open_out full_fname in
         output_string fh contents;
         close_out fh
    )
  )
