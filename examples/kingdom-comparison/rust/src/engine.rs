#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Player {
    Zero,
    One,
}

impl Player {
    fn index(self) -> usize {
        match self {
            Self::Zero => 0,
            Self::One => 1,
        }
    }

    pub fn number(self) -> u8 {
        self.index() as u8
    }

    fn other(self) -> Self {
        match self {
            Self::Zero => Self::One,
            Self::One => Self::Zero,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct State {
    gold: [u16; 2],
    bank: u16,
    owner: Player,
    mortgaged: bool,
    turn: Player,
}

impl State {
    pub fn initial() -> Self {
        Self {
            gold: [20, 20],
            bank: 100,
            owner: Player::Zero,
            mortgaged: false,
            turn: Player::Zero,
        }
    }

    pub fn gold(self, player: Player) -> u16 {
        self.gold[player.index()]
    }

    pub fn bank(self) -> u16 {
        self.bank
    }

    pub fn owner(self) -> Player {
        self.owner
    }

    pub fn mortgaged(self) -> bool {
        self.mortgaged
    }

    pub fn turn(self) -> Player {
        self.turn
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    Buy,
    Mortgage,
    Repay,
    Pass,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Command {
    action: Action,
    actor: Player,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Transition {
    pub accepted: bool,
    pub state: State,
}

fn parse_command(raw: &str) -> Option<Command> {
    let (action, actor) = match raw {
        "buy0" => (Action::Buy, Player::Zero),
        "buy1" => (Action::Buy, Player::One),
        "mortgage0" => (Action::Mortgage, Player::Zero),
        "mortgage1" => (Action::Mortgage, Player::One),
        "repay0" => (Action::Repay, Player::Zero),
        "repay1" => (Action::Repay, Player::One),
        "pass0" => (Action::Pass, Player::Zero),
        "pass1" => (Action::Pass, Player::One),
        _ => return None,
    };

    Some(Command { action, actor })
}

/// Applies one command to a value state without performing any I/O.
///
/// `None` represents a command-line token that is not valid UTF-8. It is
/// rejected in the same way as every other unknown command.
pub fn transition(state: State, raw: Option<&str>) -> Transition {
    let Some(command) = raw.and_then(parse_command) else {
        return Transition {
            accepted: false,
            state,
        };
    };

    if command.actor != state.turn {
        return Transition {
            accepted: false,
            state,
        };
    }

    let actor = command.actor.index();
    let mut next = state;
    let accepted = match command.action {
        Action::Buy
            if command.actor != state.owner && !state.mortgaged && state.gold[actor] >= 10 =>
        {
            let seller = state.owner.index();
            next.gold[actor] -= 10;
            next.gold[seller] += 10;
            next.owner = command.actor;
            true
        }
        Action::Mortgage if command.actor == state.owner && !state.mortgaged && state.bank >= 5 => {
            next.bank -= 5;
            next.gold[actor] += 5;
            next.mortgaged = true;
            true
        }
        Action::Repay
            if command.actor == state.owner && state.mortgaged && state.gold[actor] >= 5 =>
        {
            next.gold[actor] -= 5;
            next.bank += 5;
            next.mortgaged = false;
            true
        }
        Action::Pass => true,
        _ => false,
    };

    if accepted {
        next.turn = state.turn.other();
        Transition {
            accepted: true,
            state: next,
        }
    } else {
        Transition {
            accepted: false,
            state,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMANDS: [&str; 8] = [
        "buy0",
        "buy1",
        "mortgage0",
        "mortgage1",
        "repay0",
        "repay1",
        "pass0",
        "pass1",
    ];

    fn player(number: u8) -> Player {
        if number == 0 {
            Player::Zero
        } else {
            Player::One
        }
    }

    // This deliberately spells out the prompt's contract independently of the
    // production match arms. It is a test oracle, not a formal proof.
    fn expected_transition(state: State, raw: &str) -> Transition {
        let (kind, actor_number) = match raw {
            "buy0" => (0, 0),
            "buy1" => (0, 1),
            "mortgage0" => (1, 0),
            "mortgage1" => (1, 1),
            "repay0" => (2, 0),
            "repay1" => (2, 1),
            "pass0" => (3, 0),
            "pass1" => (3, 1),
            _ => {
                return Transition {
                    accepted: false,
                    state,
                };
            }
        };

        let actor = player(actor_number);
        if actor != state.turn {
            return Transition {
                accepted: false,
                state,
            };
        }

        let can_apply = match kind {
            0 => actor != state.owner && !state.mortgaged && state.gold[actor.index()] >= 10,
            1 => actor == state.owner && !state.mortgaged && state.bank >= 5,
            2 => actor == state.owner && state.mortgaged && state.gold[actor.index()] >= 5,
            3 => true,
            _ => unreachable!(),
        };
        if !can_apply {
            return Transition {
                accepted: false,
                state,
            };
        }

        let mut next = state;
        match kind {
            0 => {
                next.gold[actor.index()] -= 10;
                next.gold[state.owner.index()] += 10;
                next.owner = actor;
            }
            1 => {
                next.bank -= 5;
                next.gold[actor.index()] += 5;
                next.mortgaged = true;
            }
            2 => {
                next.gold[actor.index()] -= 5;
                next.bank += 5;
                next.mortgaged = false;
            }
            3 => {}
            _ => unreachable!(),
        }
        next.turn = player(1 - actor_number);
        Transition {
            accepted: true,
            state: next,
        }
    }

    fn total_gold(state: State) -> u16 {
        state.gold[0] + state.gold[1] + state.bank
    }

    #[test]
    fn initial_state_matches_contract() {
        assert_eq!(
            State::initial(),
            State {
                gold: [20, 20],
                bank: 100,
                owner: Player::Zero,
                mortgaged: false,
                turn: Player::Zero,
            }
        );
    }

    #[test]
    fn every_total_140_state_and_valid_command_matches_contract_oracle() {
        let mut cases = 0_u64;
        for gold0 in 0..=140_u16 {
            for gold1 in 0..=(140 - gold0) {
                let bank = 140 - gold0 - gold1;
                for owner_number in 0..=1 {
                    for mortgaged in [false, true] {
                        for turn_number in 0..=1 {
                            let state = State {
                                gold: [gold0, gold1],
                                bank,
                                owner: player(owner_number),
                                mortgaged,
                                turn: player(turn_number),
                            };
                            for raw in COMMANDS {
                                let actual = transition(state, Some(raw));
                                let expected = expected_transition(state, raw);
                                assert_eq!(actual, expected, "state={state:?}, command={raw}");
                                assert_eq!(total_gold(actual.state), 140);
                                if actual.accepted {
                                    assert_eq!(actual.state.turn, state.turn.other());
                                } else {
                                    assert_eq!(actual.state, state);
                                }
                                cases += 1;
                            }
                        }
                    }
                }
            }
        }
        assert_eq!(cases, 640_704);
    }

    #[test]
    fn unknown_tokens_and_non_utf8_marker_are_rejected_without_change() {
        let state = State::initial();
        for raw in [
            "",
            "buy",
            "buy2",
            "Buy0",
            "buy0 ",
            " buy0",
            "pass0\n",
            "mortgage00",
            "repay-1",
            "pass0 pass1",
            "💰0",
        ] {
            assert_eq!(
                transition(state, Some(raw)),
                Transition {
                    accepted: false,
                    state,
                },
                "token={raw:?}"
            );
        }
        assert_eq!(
            transition(state, None),
            Transition {
                accepted: false,
                state,
            }
        );
    }
}
