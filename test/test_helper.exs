# Auto Merge merges every approved branch; only its own tests turn it on, so an
# approval in another test never merges anything.
Application.put_env(:merge, :auto_merge, false)
ExUnit.start()
