"""Decide whether a GitHub Actions condition truly requires a guard.

Substring matching cannot answer that question: `!(github.repository == 'x')`
and `github.repository == 'x' || github.event_name == 'push'` both contain the
guard text while still running elsewhere. This module parses the condition and
asks whether it can evaluate true while the guard is false. Every other term is
treated as free, so the answer is conservative: an expression is accepted only
when the guard is a mandatory conjunct on every path.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

_IDENTIFIER_TAIL = re.compile(r"[A-Za-z0-9_.\]']$")


class ParseError(ValueError):
    """The condition is not an expression this module can reason about."""


@dataclass(frozen=True)
class Atom:
    text: str


@dataclass(frozen=True)
class Not:
    operand: Node


@dataclass(frozen=True)
class And:
    operands: tuple[Node, ...]


@dataclass(frozen=True)
class Or:
    operands: tuple[Node, ...]


Node = Atom | Not | And | Or


def normalize(text: str) -> str:
    """Collapse whitespace so folded YAML scalars compare by content."""
    return " ".join(text.split())


def tokenize(condition: str) -> list[str]:
    tokens: list[str] = []
    atom = ""
    index = 0
    quote = ""

    def flush() -> None:
        nonlocal atom
        if atom.strip():
            tokens.append(normalize(atom))
        atom = ""

    while index < len(condition):
        char = condition[index]
        if quote:
            atom += char
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "'\"":
            quote = char
            atom += char
            index += 1
            continue
        pair = condition[index : index + 2]
        if pair in ("&&", "||"):
            flush()
            tokens.append(pair)
            index += 2
            continue
        if char == "!" and pair != "!=":
            flush()
            tokens.append("!")
            index += 1
            continue
        if char == "(" and _IDENTIFIER_TAIL.search(atom.strip()):
            # A function call such as `always()` or `contains(a, 'b')` is one
            # atom, not a parenthesized subexpression.
            group, index = _consume_group(condition, index)
            atom += group
            continue
        if char == "(":
            flush()
            tokens.append("(")
            index += 1
            continue
        if char == ")":
            flush()
            tokens.append(")")
            index += 1
            continue
        atom += char
        index += 1

    if quote:
        raise ParseError(f"unterminated string in {condition!r}")
    flush()
    return tokens


def _consume_group(condition: str, start: int) -> tuple[str, int]:
    depth = 0
    quote = ""
    for index in range(start, len(condition)):
        char = condition[index]
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return condition[start : index + 1], index + 1
    raise ParseError(f"unbalanced parentheses in {condition!r}")


def parse(condition: str) -> Node:
    text = normalize(condition)
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    tokens = tokenize(text)
    if not tokens:
        raise ParseError("empty condition")
    node, rest = _parse_or(tokens)
    if rest:
        raise ParseError(f"trailing tokens {rest!r} in {condition!r}")
    return node


def _parse_or(tokens: list[str]) -> tuple[Node, list[str]]:
    node, tokens = _parse_and(tokens)
    operands = [node]
    while tokens and tokens[0] == "||":
        node, tokens = _parse_and(tokens[1:])
        operands.append(node)
    return (operands[0] if len(operands) == 1 else Or(tuple(operands)), tokens)


def _parse_and(tokens: list[str]) -> tuple[Node, list[str]]:
    node, tokens = _parse_unary(tokens)
    operands = [node]
    while tokens and tokens[0] == "&&":
        node, tokens = _parse_unary(tokens[1:])
        operands.append(node)
    return (operands[0] if len(operands) == 1 else And(tuple(operands)), tokens)


def _parse_unary(tokens: list[str]) -> tuple[Node, list[str]]:
    if not tokens:
        raise ParseError("expression ends after an operator")
    head, rest = tokens[0], tokens[1:]
    if head == "!":
        node, rest = _parse_unary(rest)
        return Not(node), rest
    if head == "(":
        node, rest = _parse_or(rest)
        if not rest or rest[0] != ")":
            raise ParseError("missing closing parenthesis")
        return node, rest[1:]
    if head in ("&&", "||", ")"):
        raise ParseError(f"unexpected token {head!r}")
    return Atom(head), rest


def _outcomes(node: Node, guard: str) -> tuple[bool, bool]:
    """Return (can be true, can be false) while the guard evaluates false."""
    if isinstance(node, Atom):
        return (not _is_guard(node.text, guard), True)
    if isinstance(node, Not):
        can_true, can_false = _outcomes(node.operand, guard)
        return (can_false, can_true)
    children = [_outcomes(operand, guard) for operand in node.operands]
    if isinstance(node, And):
        return (all(t for t, _ in children), any(f for _, f in children))
    return (any(t for t, _ in children), all(f for _, f in children))


def _is_guard(atom: str, guard: str) -> bool:
    if atom == guard:
        return True
    left, operator, right = guard.partition("==")
    return bool(operator) and atom == f"{right.strip()} == {left.strip()}"


def requires(condition: str, guard: str) -> bool:
    """True when `condition` can only hold while `guard` holds.

    An unparsable condition is reported as not requiring the guard.
    """
    try:
        node = parse(condition)
    except ParseError:
        return False
    can_be_true, _ = _outcomes(node, normalize(guard))
    return not can_be_true
