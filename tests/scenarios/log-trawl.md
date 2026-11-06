access.log in this repo is an nginx access log in combined format. Count the
5xx responses per endpoint, treating /api/users/123 and /api/users/456 as the
same endpoint (numeric path segments and query strings don't make a new
endpoint). Show the endpoints sorted by count, highest first. I get a new log
like this every morning and will want the same breakdown each time.
