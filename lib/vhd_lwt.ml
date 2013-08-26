(*
 * Copyright (C) 2011-2013 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

module Fd = struct
  open Lwt

  type fd = {
    fd: Lwt_unix.file_descr;
    lock: Lwt_mutex.t;
  }

  let open_create_common flags filename =
    lwt fd = Lwt_unix.openfile filename flags 0o664 in
    let lock = Lwt_mutex.create () in
    return {fd; lock}

  let openfile = open_create_common [ Unix.O_RDWR ]
  let create = open_create_common [ Unix.O_RDWR; Unix.O_CREAT ]

  let close t = Lwt_unix.close t.fd

  let really_read { fd; lock } offset (* in file *) n =
    let buf = Lwt_bytes.create n in
    let rec rread fd buf ofs len = 
      lwt n = Lwt_bytes.read fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rread fd buf (ofs + n) (len - n) else return () in
    Lwt_mutex.with_lock lock
      (fun () ->
        lwt _ = Lwt_unix.LargeFile.lseek fd offset Unix.SEEK_SET in
        lwt () = rread fd buf 0 n in
        return (Cstruct.of_bigarray buf)
      )

  let really_write { fd; lock } offset (* in file *) buf =
    let ofs = buf.Cstruct.off in
    let len = buf.Cstruct.len in
    let buf = buf.Cstruct.buffer in

    let rec rwrite fd buf ofs len =
      lwt n = Lwt_bytes.write fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rwrite fd buf (ofs + n) (len - n) else return () in
    Lwt_mutex.with_lock lock
      (fun () ->
        lwt _ = Lwt_unix.LargeFile.lseek fd offset Unix.SEEK_SET in
        rwrite fd buf ofs len
      )
end

module File = struct
  type 'a t = 'a Lwt.t

  let (>>=) = Lwt.(>>=)
  let return = Lwt.return
  let fail = Lwt.fail

  let exists path = return (try ignore(Unix.stat path); true with _ -> false)

  let y2k = 946684800.0 (* seconds from the unix epoch to the vhd epoch *)

  let get_vhd_time time =
    Int32.of_int (int_of_float (time -. y2k))

  let now () =
    let time = Unix.time() in
    get_vhd_time time

  let get_modification_time x =
    let st = Unix.stat x in
    return (get_vhd_time (st.Unix.st_mtime))

  include Fd

end

module Impl = Vhd.Make(File)
include Impl
include Fd 