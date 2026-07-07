import unittest

from qa_logger.redact import redact_value


class RedactionTests(unittest.TestCase):
    def test_redacts_sensitive_looking_assignment_without_value_leak(self):
        payload = {
            "summary": "demo field api_key=DEMO_SECRET_VALUE_12345 should not persist",
            "nested": ["normal text", "password=DEMO_PASSWORD_VALUE_12345"],
        }

        redacted, findings = redact_value(payload)

        rendered = str(redacted)
        self.assertNotIn("DEMO_SECRET_VALUE_12345", rendered)
        self.assertNotIn("DEMO_PASSWORD_VALUE_12345", rendered)
        self.assertIn("[REDACTED:credential_field]", rendered)
        self.assertEqual({finding.category for finding in findings}, {"credential_field"})


if __name__ == "__main__":
    unittest.main()
