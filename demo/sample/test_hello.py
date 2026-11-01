import unittest

from hello import greeting


class TestHello(unittest.TestCase):
    def test_default(self):
        self.assertEqual(greeting(), "hello, world")

    def test_name(self):
        self.assertEqual(greeting("phext"), "hello, phext")


if __name__ == "__main__":
    unittest.main()
