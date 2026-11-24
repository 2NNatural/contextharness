import unittest, pricing
class T(unittest.TestCase):
    def test_discount(self):
        self.assertEqual(pricing.apply_discount(1000, 10), 900)
    def test_tax(self):
        self.assertEqual(pricing.apply_tax(1000, 10), 1100)
    def test_total(self):
        self.assertEqual(pricing.order_total([(500, 2)], 10, 10), 990)
if __name__ == "__main__":
    unittest.main()
