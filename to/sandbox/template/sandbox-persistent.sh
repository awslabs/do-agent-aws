# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# do-agent-aws sandbox: proxy environment coherence (begin)
# The sbx runtime injects the egress proxy as upper-case HTTP_PROXY/HTTPS_PROXY/NO_PROXY. The
# harness .env also exports empty lower-case http_proxy=/https_proxy= (correct on a host with no
# proxy); carried into the sandbox those empty values shadow the upper-case ones for every client
# that reads the lower-case names - notably Python urllib/botocore, which the memory API
# (hindsight-api) uses - so that client bypasses the egress proxy and never receives the
# proxy-injected Bedrock credential (AWS then rejects the untouched sentinel with 403 "Invalid
# API Key format"). Mirror a set name into an empty-or-unset partner of the opposite case so every
# client uses the one egress proxy. Nothing set on either side leaves the environment unchanged.
for _pp in HTTP_PROXY:http_proxy HTTPS_PROXY:https_proxy NO_PROXY:no_proxy; do
	_u=${_pp%:*}; _l=${_pp#*:}
	eval "_uv=\${$_u-}"; eval "_lv=\${$_l-}"
	if [ -n "$_uv" ] && [ -z "$_lv" ]; then eval "export $_l=\"\$$_u\""; fi
	if [ -z "$_uv" ] && [ -n "$_lv" ]; then eval "export $_u=\"\$$_l\""; fi
done
unset _pp _u _l _uv _lv
# do-agent-aws sandbox: proxy environment coherence (end)
