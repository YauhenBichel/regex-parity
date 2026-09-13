# Security

## Reporting

Please report a vulnerability through GitHub's private advisory form on this repository
("Security" → "Report a vulnerability"), not in a public issue. I aim to reply within a week.

A rule that can be walked past with a look-alike character, an invisible character or an engine
difference counts as a vulnerability here, even though no code is compromised: regex-parity exists so
that a rule means the same thing everywhere it runs.

## What is in this repository today

- The libraries read the text and patterns you give them and send nothing anywhere. The demo page
  loads Pyodide from jsDelivr to run Python in your browser.
- Libraries in `packages/` and a demo page. Nothing is published to a package registry yet.
