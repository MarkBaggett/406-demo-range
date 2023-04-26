## Demo range setup instructions.

Prerequisites:

1. Install [terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
2. Setup AWS [credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)  

First clone the repo to your host.
```
git clone 
```

Once you have the `source.tgz` file.

```
tar -xzf source.tgz -C < path to git repo >
```

Then run these commands.

```
terraform init
terraform plan -out range.plan
terraform apply range.plan
```
Observe the instructions for connecting to the environment. 

```
terraform output
````

Once down with environment, to shutdown the range and destroy all resources.  

```
terraform apply --auto-approve -destroy 
```

