import Base

type Booking is Data:
  Booking{id: Nat, room: Nat, start: Nat, end: Nat}

type State is Data:
  State{bookings: List<&2, Booking>, keys: List<&2, Nat>}

type Status is Data:
  Applied{}
  Replayed{}
  Rejected{}

type Outcome is Data:
  Outcome{status: Status, state: State}
