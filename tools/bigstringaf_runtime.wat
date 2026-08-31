;; wasm_of_ocaml runtime shim for bigstringaf.
;;
;; bigstringaf ships only a JavaScript runtime (runtime.js), so a wasm_of_ocaml
;; build of anything that depends on it (angstrom, faraday, httpaf, ...) warns
;;   Warning [missing-primitive]: bigstringaf_blit_to_bytes, bigstringaf_blit_from_bytes
;; and emits dummy implementations that raise at runtime.
;;
;; Both primitives already exist in the wasm_of_ocaml runtime under the OCaml
;; stdlib names with identical signatures, so this file just re-exports them.
;;
;; The imports must name the module "env": wasm_of_ocaml merges the prelinked
;; runtime and every user-supplied runtime file under that single name (see the
;; wasm-merge invocation it runs). Importing from "bigstring" -- the name of the
;; runtime source file these functions live in -- leaves an unresolvable import
;; in the final module.
;;
;; Usage:
;;   wasm_of_ocaml compile --effects=native --enable wasi \
;;     tools/bigstringaf_runtime.wat prog.byte -o prog.js
(module
   (import "env" "caml_bigstring_blit_ba_to_bytes"
      (func $blit_ba_to_bytes
         (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq))
         (param (ref eq)) (result (ref eq))))
   (import "env" "caml_bigstring_blit_bytes_to_ba"
      (func $blit_bytes_to_ba
         (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq))
         (param (ref eq)) (result (ref eq))))

   ;; bigstringaf_blit_to_bytes (src : bigstring) src_off (dst : bytes) dst_off len
   (func (export "bigstringaf_blit_to_bytes")
      (param $src (ref eq)) (param $src_off (ref eq))
      (param $dst (ref eq)) (param $dst_off (ref eq))
      (param $len (ref eq)) (result (ref eq))
      (call $blit_ba_to_bytes
         (local.get $src) (local.get $src_off)
         (local.get $dst) (local.get $dst_off) (local.get $len)))

   ;; bigstringaf_blit_from_bytes (src : bytes) src_off (dst : bigstring) dst_off len
   (func (export "bigstringaf_blit_from_bytes")
      (param $src (ref eq)) (param $src_off (ref eq))
      (param $dst (ref eq)) (param $dst_off (ref eq))
      (param $len (ref eq)) (result (ref eq))
      (call $blit_bytes_to_ba
         (local.get $src) (local.get $src_off)
         (local.get $dst) (local.get $dst_off) (local.get $len)))
)
