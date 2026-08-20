"""Conservative checks for canonical GitHub Actions job guards."""

from __future__ import annotations

import ast

STATUS_CHECKS = frozenset({"always", "cancelled", "failure", "success"})


class ParseError(ValueError):
    """The condition is not an expression this module can reason about."""


def normalize(text: str) -> str:
    """Collapse whitespace so folded YAML scalars compare by content."""
    return " ".join(text.split())


def _python_syntax(condition: str) -> str:
    """Translate GitHub's Boolean operators without changing string literals."""
    text = normalize(condition)
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()

    translated: list[str] = []
    index = 0
    quoted = False
    while index < len(text):
        char = text[index]
        if char == "'":
            translated.append(char)
            if quoted and text[index : index + 2] == "''":
                translated.append("'")
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if not quoted:
            pair = text[index : index + 2]
            if pair == "&&":
                translated.append(" and ")
                index += 2
                continue
            if pair == "||":
                translated.append(" or ")
                index += 2
                continue
            if char == "!" and pair != "!=":
                translated.append(" not ")
                index += 1
                continue
        translated.append(char)
        index += 1

    if quoted:
        raise ParseError(f"unterminated string in {condition!r}")
    return "".join(translated).strip()


def parse(condition: str) -> ast.expr:
    try:
        return ast.parse(_python_syntax(condition), mode="eval").body
    except (SyntaxError, ValueError) as error:
        raise ParseError(str(error)) from error


def _same(left: ast.AST, right: ast.AST) -> bool:
    return ast.dump(left, include_attributes=False) == ast.dump(
        right, include_attributes=False
    )


def _outcomes(node: ast.expr, guard: ast.expr) -> tuple[bool, bool]:
    """Return (can be true, can be false) while the guard is false."""
    if _same(node, guard):
        return False, True
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        can_true, can_false = _outcomes(node.operand, guard)
        return can_false, can_true
    if isinstance(node, ast.BoolOp):
        children = [_outcomes(value, guard) for value in node.values]
        if isinstance(node.op, ast.And):
            return all(can_true for can_true, _ in children), any(
                can_false for _, can_false in children
            )
        return any(can_true for can_true, _ in children), all(
            can_false for _, can_false in children
        )
    # Every unrelated expression is free to be true or false. This can reject
    # an unusual but safe condition, but it cannot approve an unsafe one.
    return True, True


def requires(condition: str, guard: str) -> bool:
    """Return whether a condition requires the exact, canonical guard AST."""
    try:
        expression = parse(condition)
        guard_expression = parse(guard)
    except ParseError:
        return False
    can_be_true, _ = _outcomes(expression, guard_expression)
    return not can_be_true


def overrides_implicit_success(condition: str) -> bool:
    """Return whether a condition names a GitHub status-check function."""
    if not normalize(condition):
        return False
    try:
        expression = parse(condition)
    except ParseError:
        return True
    return any(
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id.lower() in STATUS_CHECKS
        for node in ast.walk(expression)
    )
