Okay I tested it out. It is mostly correct, but I need some changes.

- User shouldn't be allowed to enter Tasklist buffer before
  authenticating. Send a nice messsage that they need to authenticate
  first.
- Deletion does not work properly. I delete the task, it remains on
  Google Tasks. I do `TasksPurge`, and it doesn't disappear from
  Google Tasks. I do `TasksSync` and my deleted task comes back.
- Conceal is not working properly. It is hidden on lines that I'm not
  on, but on my current line, it shows metadata like ID that should be
  hidden.
- The plugin should not allow the user to enter the part of the line
  that contains the ID. See oil.nvim for example of how it prevents
  the cursor from entering certain parts of the line.
