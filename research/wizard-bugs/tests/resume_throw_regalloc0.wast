;; Regression: SPC/JIT lowering of `resume_throw` moved the continuation-stack
;; operand into runtime_arg2 *after* loading the instance into runtime_arg1,
;; so when the register allocator placed the operand in runtime_arg1 the runtime
;; received the module instance in place of the continuation stack. The runtime
;; then unwound the *instance* object as if it were a stack, corrupting its
;; `tables` field; the next `table.get` dereferenced the corrupted field and
;; trapped with a spurious null-check. Interpreter tier was unaffected.
(module
  (type $ft (func (result i32)))
  (type $ct (cont $ft))
  (tag $cancel (param i32 i32))
  (tag $yield (param i32 i32))
  (table $t 1 (ref null $ct))

  (func $worker (type $ft) (result i32)
    (suspend $yield (i32.const 7) (i32.const 8))
    (i32.const 99))
  (elem declare func $worker)

  (func (export "main") (result i32)
    (local $a i32) (local $k (ref null $ct))
    (block $done (result i32)
      (block $on_yield (result i32 i32 (ref $ct))
        (resume $ct (on $yield $on_yield)
          (cont.new $ct (ref.func $worker)))
        (br $done))
      ;; [7 8 k] : worker suspended; keep k, discard the payload
      (local.set $k) (drop) (drop)
      ;; cancel the worker; it has no handler for $cancel, so the exception
      ;; unwinds out of the worker and is caught here.
      (block $on_cancel (result i32 i32)
        (try_table (result i32 i32) (catch $cancel $on_cancel)
          (i32.add (local.get $a) (i32.const 1))   ;; raise register pressure so the
          (i32.add (local.get $a) (i32.const 2))   ;; cont-stack operand lands in an arg reg
          (i32.const 7) (i32.const 8)
          (local.get $k)
          (resume_throw $ct $cancel)
          (unreachable)))
      (drop) (drop)
      ;; touch the table: reads instance.tables, which the bug corrupted.
      (table.get $t (i32.const 0))
      (ref.is_null) (drop)
      (i32.const 42)))
)
(assert_return (invoke "main") (i32.const 42))
