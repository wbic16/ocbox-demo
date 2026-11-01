"""Tiny demo program for the ocbox x phext MVP."""


def greeting(name="world"):
    return f"hello, {name}"


if __name__ == "__main__":
    print(greeting())
    print("hello from the remote session (which is really a local shim)")
