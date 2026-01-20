You are tasked with creating a Neovim plugin.

The plugin will allow users to manage their Google Task collection via
Neovim.

It will function similar to oil.nvim. See `AGENTS.md` for references
to that plugin.

When the user activates the plugin via something like `:Tasks`, it
will open a Neovim buffer. Each line in that buffer will represent a
task. Metadata will be associated with a task. For example:

- `- [ ] 2024-01-18 Do laundry` will represent an uncompleted
  task that is due on January 18th, 2024.
- `- [x] Get milk` will represent a completed task that has no due
  date

The plugin will follow oil.nvim's example. Hidden IDs will be embedded
at the start of the line that is concealed from the user. This will
help the plugin identify whether the user is:

- Creating a new task
- Updating an existing task
- Deleting an existing task

There is an edge case where the user may yank the entire line via
something like `VYp` in normal mode. Create an autocmd so that
whenever the user yanks, it strips the Task ID from it.

Whenever the user saves the buffer, send a request to the Google Tasks
API to update their tasklist in the cloud. Use OAUTH and cache
refresh/access tokens in a file on disk.

I want auth to be completed with a local redirect server in lua, and
activated by the user via a command like `TasksAuth`.

Also, when the user activates the plugin via something like `:Tasks`,
the newly opened buffer should be pre-populated with lines associated
with the result of reading from the remote Google Tasks store.

The plugin will prioritize user experience.

The plugin will prioritize speed and efficiency over remote data
correctness. What I mean by this is the opening of the Tasklist buffer
and the closing of the tasklist buffer should be **instant**.

How do I want you to accomplish this? You should cache the previous
known Tasklist in a file on disk. Even if this is stale relative to
the remote Tasklist, initially populate the Tasklist buffer with this
file's contents, and then async send a request to get the new Tasklist
from the remote. In other words, follow a **Stale-While-Revalidate
(SWR)** Pattern.

Of course, also cache the updated tasklist to the same file on disk.
When the user closes the tasklist buffer, I don't want it to hang
while it ensures the data is synced to the remote. I will need ideas
of how to ensure the plugin know's whether the local file is stale or
the remote is stale, since these could both be options.
