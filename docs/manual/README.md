# Do Agent on AWS manual

The reference for the harness, one page per topic. Start with the [README](../../README.md) for what it is and a quickstart.

| Page | What it covers |
|---|---|
| [Installing and running](install.md) | How to install the harness, run it, configure it and keep its state. Sections: [Installation](install.md#installation), [Container project description](install.md#container-project-description), [What runs](install.md#what-runs), [Settings](install.md#settings), [Setup doctor](install.md#setup-doctor), [Docker Sandboxes](install.md#docker-sandboxes), [Persistent agent state](install.md#persistent-agent-state), [Container user](install.md#container-user), [Git identity](install.md#git-identity). |
| [AWS credentials and Amazon Bedrock](aws.md) | How the harness gets AWS credentials and reaches Amazon Bedrock. Sections: [AWS credentials](aws.md#aws-credentials), [Credentials from AWS Secrets Manager](aws.md#credentials-from-aws-secrets-manager), [Bedrock connectivity](aws.md#bedrock-connectivity). |
| [Memory and learning](memory.md) | What the agent remembers, how it learns from its own work, and how knowledge moves between harnesses. Sections: [Agent memory](memory.md#agent-memory), [Agent learning tools](memory.md#agent-learning-tools), [Moving knowledge between instances](memory.md#moving-knowledge-between-instances), [A shared knowledge base for a group](memory.md#a-shared-knowledge-base-for-a-group). |
| [The autonomy loop](autonomy.md) | How the agent works on goals by itself, and how it compares with a native Claude Code instance. Sections: [Autonomy loop](autonomy.md#autonomy-loop), [Parity with a native instance](autonomy.md#parity-with-a-native-instance). |
| [Slack and other channels](channels.md) | How the agent watches and answers Slack, and the comms engine's channels. Sections: [Slack connectivity](channels.md#slack-connectivity), [Comms UI](channels.md#comms-ui). |
| [The harness UIs](ui.md) | The home page, its reverse proxy and every UI behind it. Sections: [Harness UIs](ui.md#harness-uis), [Home page and reverse proxy](ui.md#home-page-and-reverse-proxy), [Files](ui.md#files). |
| [Spoke agents and the Docker agent](agents.md) | The supervisor, the spoke agents beside the hub agent, and the Docker agent's build substrate. Sections: [Spoke agents](agents.md#spoke-agents), [Docker agent](agents.md#docker-agent). |
| [The boards](boards.md) | The Goals board (vibe-kanban), the optional Plane project board and the Board page. Sections: [Kanban board](boards.md#kanban-board), [Plane board](boards.md#plane-board), [Board](boards.md#board). |
| [Software bill of materials and CVE scan](supply-chain.md) | What every build records about the software it installs, and how it is scanned. Sections: [Software bill of materials](supply-chain.md#software-bill-of-materials), [CVE scan](supply-chain.md#cve-scan). |

Other documents: [the personas and their quickstarts](../PERSONAS.md), [status against the goals](../STATUS.md),
[the North Star](../NORTH-STAR.md), [the agent stack](../AGENT-STACK.md), [how the agents talk](../INTER-AGENT-MESSAGING.md),
[coding through the kanban board](../guides/kanban-coding.md), [Docker Sandboxes](../../to/sandbox/README.md) and
[security](../../SECURITY.md).
