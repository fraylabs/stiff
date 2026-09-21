mod engine;

use engine::{transition, Player, State};

fn main() {
    let mut state = State::initial();

    for token in std::env::args_os().skip(1) {
        let result = transition(state, token.to_str());
        state = result.state;
        let status = if result.accepted { "ok" } else { "error" };
        println!(
            "{} {} {} {} {} {} {}",
            status,
            state.gold(Player::Zero),
            state.gold(Player::One),
            state.bank(),
            state.owner().number(),
            u8::from(state.mortgaged()),
            state.turn().number()
        );
    }
}
