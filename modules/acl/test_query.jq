(.rules | to_entries[] as $e | 
  ("rule|\($e.key)|has_files|\(if ($e.value.acl | type) == "object" then (($e.value.acl.files // [])|length) > 0 else false end)")
)