import Base
import ./contracts.bend as C

law case_sensitive_method:
  {C.select([C.Route{0n, "GET", "/x", False{}, Nil{}}], "get", "/x")
    == C.WrongMethod{["GET"]} : C.Selection}
def case_sensitive_method():
  {==}

law empty_capture_rejected:
  {C.match_path("/x/:id", "/x/") == C.NoMatch{} : C.Match}
def empty_capture_rejected():
  {==}

law first_route_wins:
  {C.select([C.Route{0n, "GET", "/:id", False{}, Nil{}}, C.Route{1n, "GET", "/x", True{}, Nil{}}], "GET", "/x")
    == C.Found{C.Route{0n, "GET", "/:id", False{}, Nil{}}, [C.Param{"id", "x"}]} : C.Selection}
def first_route_wins():
  {==}

law allow_last_occurrence_order:
  {C.select([C.Route{0n, "GET", "/x", False{}, Nil{}}, C.Route{1n, "POST", "/x", False{}, Nil{}}, C.Route{2n, "GET", "/x", False{}, Nil{}}], "DELETE", "/x")
    == C.WrongMethod{["POST", "GET"]} : C.Selection}
def allow_last_occurrence_order():
  {==}

law raw_segments_and_capture_order:
  {C.match_path("/:a//:b/", "/%2F//X/")
    == C.Matched{[C.Param{"a", "%2F"}, C.Param{"b", "X"}]} : C.Match}
def raw_segments_and_capture_order():
  {==}

law empty_parameter_name_rejected:
  {C.match_path("/:", "/x") == C.NoMatch{} : C.Match}
def empty_parameter_name_rejected():
  {==}
