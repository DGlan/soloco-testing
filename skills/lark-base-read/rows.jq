.data as $d
| {
    count: ($d.data | length),
    has_more: $d.has_more,
    rows: [
      range(0; $d.data | length) as $i
      | ([$d.fields, $d.data[$i]] | transpose | map({key: .[0], value: .[1]}) | from_entries)
        + {record_id: $d.record_id_list[$i]}
      | {record_id, title: ."标题", status: ."状态", severity: ."严重程度", module: ."所属模块", kind: ."问题类型"}
    ]
  }
