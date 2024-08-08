(module
  (export "_start" (func $_start))
  (func $_start
    i64.const 15
    i64.const 3
    i64.add
    drop

    i64.const 15
    i64.const 3
    i64.sub
    drop

    f64.const 15.5
    f64.const 3.0
    f64.add
    drop

    i64.const -15
    i64.const 3
    i64.div_s
    drop

    i64.const -15
    i64.const 3
    i64.div_u
    drop

    i64.const 15
    i64.const 3
    i64.rem_s
    drop

    i64.const 15
    i64.const 3
    i64.rem_u
    drop
  )
)
