;; Minimal all-three-opcodes workload, mirroring fiber-c examples/itersum_switch.c
;; without C, tables, globals or linear memory.
;;   main --resume--> consumer --switch--> producer --switch--> consumer ... 
;;   producer finishes with `suspend $done`, main resumes the consumer with the result.
(module
  (rec
    (type $ft (func (param i32 (ref null $ct)) (result i32)))
    (type $ct (cont $ft)))
  (type $ftr (func (result i32)))          ;; type of a fiber parked at `suspend $done`
  (type $ctr (cont $ftr))
  (tag $yield (result i32))                ;; tag 0: the switch tag
  (tag $done (param i32 (ref null $ct)))   ;; tag 1: producer finished; payload = (result, consumer cont)

  (func $producer (type $ft) (param $n i32) (param $k (ref null $ct)) (result i32)
    (local $i i32)
    (block $exit
      (loop $l
        (br_if $exit (i32.ge_s (local.get $i) (local.get $n)))
        (switch $ct $yield (local.get $i) (local.get $k))   ;; [i32 (ref null $ct)] -> [i32 (ref null $ct)]
        (local.set $k)
        (drop)
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (suspend $done (i32.const 0) (local.get $k))
    (unreachable))

  (func $consumer (type $ft) (param $n i32) (param $k0 (ref null $ct)) (result i32)
    (local $p (ref null $ct)) (local $sum i32) (local $v i32) (local $i i32)
    (local.set $p (cont.new $ct (ref.func $producer)))
    (switch $ct $yield (local.get $n) (local.get $p))       ;; start the producer, passing n
    (local.set $p)
    (local.set $v)
    (loop $l
      (local.set $sum (i32.add (local.get $sum) (local.get $v)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (switch $ct $yield (i32.const 0) (local.get $p))      ;; last one returns via main's resume
      (local.set $p)
      (local.set $v)
      (br_if $l (i32.lt_s (local.get $i) (local.get $n))))
    (local.get $sum))

  (func $main (export "main") (param $n i32) (result i32)
    (local $k (ref null $ct)) (local $ck (ref null $ct)) (local $r i32)
    (local.set $k (cont.new $ct (ref.func $consumer)))
    (block $finished (result i32)
      (block $onDone (result i32 (ref null $ct) (ref $ctr))
        (resume $ct (on $yield switch) (on $done $onDone)
          (local.get $n) (ref.null $ct) (local.get $k))
        (br $finished))
      ;; producer finished: [result consumer_k producer_k]
      (drop)                    ;; producer_k is abandoned (fiber-c cancels it with resume_throw)
      (local.set $ck)
      (local.set $r)
      (block $onDone2 (result i32 (ref null $ct) (ref $ctr))
        (resume $ct (on $yield switch) (on $done $onDone2)
          (local.get $r) (ref.null $ct) (local.get $ck))
        (br $finished))
      (unreachable)))
  (elem declare func $producer $consumer)
)
