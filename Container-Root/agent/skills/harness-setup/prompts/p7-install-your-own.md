# Install your own, as a conversation

For a person who wants this harness on their own machine. You run inside a harness already, so everything below is
host lines for the person, on their machine. One step per turn.

1. Ask: "Which machine: an EC2 instance with an instance role, or a laptop with an AWS profile?"
2. Ask them to check the prerequisites and tell you what is missing: Docker with buildx (`docker buildx version`),
   about 30 GB free where Docker keeps its images, git, and AWS credentials with Bedrock model access in their region.
3. Print the lines, for their machine:

   ```sh
   git clone https://github.com/awslabs/do-agent-aws.git && cd do-agent-aws
   export AWS_REGION=us-east-1          # a region where the account has model access
   export AWS_PROFILE=<your profile>    # on a laptop; with an EC2 instance role, leave it unset
   ./build.sh && ./run.sh
   ```

4. The home page is http://localhost:8000; from another machine, tunnel to it first with
   `ssh -L 8000:localhost:8000 <host>`.
5. In their new harness, `/setup` in the agent's terminal walks the same doctor there.
