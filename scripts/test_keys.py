import base64
import os
import subprocess
import unittest
from unittest.mock import patch
import keys

class KeyTests(unittest.TestCase):
    def setUp(self):
        private=os.urandom(32)
        result=subprocess.run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=keys.PRIVATE_PREFIX+private,capture_output=True,check=True)
        self.private=base64.urlsafe_b64encode(private).decode().rstrip('=')
        self.public=base64.urlsafe_b64encode(result.stdout[-32:]).decode().rstrip('=')

    def test_old_and_new_xray_labels(self):
        for label in ['Public key','Password','Password (Public key)']:
            pair=keys.parse(f'Private key: {self.private}\n{label}: {self.public}\nHash32: invalid-hash\n')
            self.assertEqual(pair,dict(private=self.private,public=self.public))

    def test_hash_is_not_a_public_key(self):
        with self.assertRaises(ValueError): keys.parse(f'PrivateKey: {self.private}\nHash32: {self.public}')

    def test_mismatched_pair_is_rejected(self):
        wrong=base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')
        with self.assertRaises(ValueError): keys.parse(f'PrivateKey: {self.private}\nPublicKey: {wrong}')

    def test_conflicting_fields_are_rejected(self):
        with self.assertRaises(ValueError): keys.parse(f'PrivateKey: {self.private}\nPublicKey: {self.public}\nPassword: different')

    def test_invalid_key_lengths_and_syntax(self):
        for value in ['abc','a'*42,'a'*44,'$(echo secret)','a'*43+'===']:
            with self.assertRaises(ValueError): keys.decode(value)

    def test_openssl_failure_is_rejected(self):
        with patch('keys.subprocess.run',return_value=subprocess.CompletedProcess([],1,b'',b'private material')):
            with self.assertRaises(ValueError): keys.parse(f'PrivateKey: {self.private}\nPublicKey: {self.public}')

if __name__=='__main__': unittest.main()
