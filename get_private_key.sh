# Get the generated key name
KEY_NAME=$(terraform output -raw key_pair_name)

# Save the private key to ~/.ssh/<key_name>.pem
terraform output -raw private_key_pem > ~/.ssh/${KEY_NAME}.pem

# Secure the key file
chmod 600 ~/.ssh/${KEY_NAME}.pem