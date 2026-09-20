import Base

# No Stiff imports: isolates the pinned compiler/runtime from Stiff's effects.
def main() -> IO(Unit):
  IO.print("runtime smoke")
