.data as $d
| [ range(0; $d.data | length) as $i
    | ([$d.fields, $d.data[$i]] | transpose | map({key: .[0], value: .[1]}) | from_entries) ]
| {
    scope: {read: ($d.data|length), has_more: $d.has_more},
    by_severity: (map(."严重程度"[0] // "(空)") | group_by(.) | map({k: .[0], n: length})),
    by_module:   (map(."所属模块"[0] // "(空)")   | group_by(.) | map({k: .[0], n: length})),
    by_kind:     (map(."问题类型"[0] // "(空)")   | group_by(.) | map({k: .[0], n: length})),
    by_status:   (map(."状态"[0] // "(空)")       | group_by(.) | map({k: .[0], n: length}))
  }
