;; Regression for a GC-safety hole in X86_64Runtime.runtime_handle_switch.
;;
;; The switch runtime detached the switching stack from its parent
;;   prev.parent = null; prev.parent_rsp_ptr.store(NULL)
;; *before* its last heap allocation, `curStack.push(Value.Cont(this_cont))`.
;; A collection triggered by that allocation walks the native stack starting on
;; the still-running switcher and reaches the ancestor stacks only through those
;; two links; with them already nulled the walk stopped after a single frame, so
;; every root held in an ancestor frame was missed -- in particular the pointer
;; to the outermost continuation stack in X86_64Stack.resume's frame on the
;; initial stack. The next collection aborted with
;;   !GcError: invalid reference ... in NativeStackScanner.scanStack()
;; and where the phase differed the run instead returned a wrong result.
;; runtime_handle_suspend already detaches *after* its allocations, which is why
;; only `switch` was affected.
;;
;; Two properties make this fire in practice:
;;   * the switch carries no value payload, so `popN` (which runs before the
;;     detach) allocates almost nothing and the post-detach `push` dominates the
;;     per-switch allocation;
;;   * the small pseudo-random allocation in the loop decorrelates the collector
;;     phase from the loop period. Without it every collection in a given run
;;     lands at the same offset within the switch and raising the iteration
;;     count does not help.
;; Even so this is a stochastic guard: it samples the window rather than hitting
;; it deterministically. 30 000 000 switches (~7 s) detected the bug from every
;; invocation phase tried on a stock -heap-size=700m build; a smaller count did
;; not. Because of that cost it belongs in test/stress/ rather than in the
;; regression suite.
(module
  (rec
    (type $ft (func (param (ref null $ct)) (result i32)))
    (type $ct (cont $ft)))
  (type $ftr (func (result i32)))
  (type $ctr (cont $ftr))
  (type $arr (array (mut i32)))
  (tag $yield (result i32))
  (tag $done (param i32 (ref null $ct)))

  (func $producer (type $ft) (param $k (ref null $ct)) (result i32)
    (local $i i32) (local $x i32)
    (local.set $x (i32.const 1))
    (block $exit
      (loop $l
        (br_if $exit (i32.ge_s (local.get $i) (i32.const 30000000)))
        (local.set $x (i32.add (i32.mul (local.get $x) (i32.const 1103515245)) (i32.const 12345)))
        (if (i32.eqz (i32.and (i32.shr_u (local.get $x) (i32.const 16)) (i32.const 31)))
          (then (drop (array.new_default $arr
                        (i32.and (i32.shr_u (local.get $x) (i32.const 21)) (i32.const 7))))))
        (local.set $k (switch $ct $yield (local.get $k)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (suspend $done (i32.const 0) (local.get $k))
    (unreachable))

  (func $consumer (type $ft) (param $k0 (ref null $ct)) (result i32)
    (local $p (ref null $ct)) (local $cnt i32)
    (local.set $p (cont.new $ct (ref.func $producer)))
    (loop $l
      (local.set $p (switch $ct $yield (local.get $p)))
      (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
      (br_if $l (i32.lt_s (local.get $cnt) (i32.const 30000000))))
    (local.get $cnt))

  (func $run (result i32)
    (local $k (ref null $ct)) (local $ck (ref null $ct)) (local $r i32)
    (local.set $k (cont.new $ct (ref.func $consumer)))
    (block $finished (result i32)
      (block $onDone (result i32 (ref null $ct) (ref $ctr))
        (resume $ct (on $yield switch) (on $done $onDone)
          (ref.null $ct) (local.get $k))
        (br $finished))
      (drop) (local.set $ck) (local.set $r)
      (block $onDone2 (result i32 (ref null $ct) (ref $ctr))
        (resume $ct (on $yield switch) (on $done $onDone2)
          (ref.null $ct) (local.get $ck))
        (br $finished))
      (unreachable)))

  (func (export "main") (result i32) (call $run))
  (elem declare func $producer $consumer)
)
(assert_return (invoke "main") (i32.const 30000000))
