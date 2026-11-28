// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
/* do-agent-aws's harness view of the claude-mem viewer. The proxy injects it into the viewer's page while
 * CLAUDE_MEM_VIEWER_WRAPPER=true (.env); it works in the browser only and touches no stored memory.
 *  - A prompt card whose text is one of the harness's own machine prompts (the autonomy loop's, its supervisor mode's
 *    workers', the Slack chat responder's) is folded into a closed, labelled disclosure, so human prompts, summaries and observations read
 *    first; the full text, as stored, is one click away.
 *  - The page's root element gets the class adav-harness-view; harness-view.css then hides the trial promotion and
 *    the social links. Documentation, GitHub, settings, the project filter and the console stay.
 *  - A small note says the view is the harness's and switches this browser to the stock viewer and back.
 */
(function () {
	"use strict";
	var MACHINE = [
		["You are one fire of the do-agent-aws autonomy loop.", "Loop instructions"],
		["You are one fire of the do-agent-aws autonomy loop - a WORKER of its supervisor mode.", "Loop instructions"],
		["SLACK CHAT: you are the do-agent-aws answering one Slack message.", "Chat responder instructions"]
	];
	var STOCK_KEY = "do-agent-aws-claude-mem-stock-view";

	function stock() {
		try {
			return window.localStorage.getItem(STOCK_KEY) === "1";
		} catch (e) {
			return false;
		}
	}

	function setStock(on) {
		try {
			if (on) {
				window.localStorage.setItem(STOCK_KEY, "1");
			} else {
				window.localStorage.removeItem(STOCK_KEY);
			}
		} catch (e) {
			return;
		}
		window.location.reload();
	}

	function fold(content) {
		if (content.hasAttribute("data-adav-machine")) {
			return;
		}
		var text = (content.textContent || "").replace(/^\s+/, "");
		for (var i = 0; i < MACHINE.length; i++) {
			if (text.indexOf(MACHINE[i][0]) !== 0) {
				continue;
			}
			var lines = text.replace(/\s+$/, "").split("\n").length;
			var box = document.createElement("details");
			box.className = "adav-machine-prompt";
			var label = document.createElement("summary");
			label.textContent = MACHINE[i][1] + " (machine prompt, " + lines + (lines === 1 ? " line)" : " lines)");
			var body = document.createElement("div");
			body.className = "adav-machine-prompt-text";
			body.textContent = text;
			box.appendChild(label);
			box.appendChild(body);
			content.setAttribute("data-adav-machine", "");
			content.parentNode.insertBefore(box, content);
			return;
		}
	}

	function scan() {
		var cards = document.querySelectorAll(".prompt-card .card-content");
		for (var i = 0; i < cards.length; i++) {
			fold(cards[i]);
		}
	}

	function note(stockView) {
		if (document.getElementById("adav-harness-view-note") || !document.body) {
			return;
		}
		var n = document.createElement("div");
		n.id = "adav-harness-view-note";
		n.setAttribute("role", "note");
		n.appendChild(document.createTextNode(stockView ? "Stock claude-mem viewer" : "Harness view: machine prompts folded, promotion hidden"));
		var b = document.createElement("button");
		b.type = "button";
		b.textContent = stockView ? "Harness view" : "Stock viewer";
		b.addEventListener("click", function () {
			setStock(!stockView);
		});
		n.appendChild(b);
		document.body.appendChild(n);
	}

	var stockView = stock();
	if (!stockView) {
		document.documentElement.classList.add("adav-harness-view");
	}
	var pending = false;
	function update() {
		pending = false;
		note(stockView);
		if (!stockView) {
			scan();
		}
	}
	new MutationObserver(function () {
		if (!pending) {
			pending = true;
			window.requestAnimationFrame(update);
		}
	}).observe(document.documentElement, {childList: true, subtree: true});
	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", update);
	} else {
		update();
	}
})();
