# Routine fixtures (GAIA_ROUTINES_HLD.md §17 R1, §18)

Local job postings for live R1 and R2 runs, with fake materials. No personal data.

1. Serve this folder: `python -m http.server 8765` from here.
2. Make a Gaia project whose folder holds `materials/profile.md`, `materials/answers.md` and any PDF as `resume.pdf`.
3. In the Routines tab, add a routine in that project. For an R1 check, set Submit to "Submit when sure", and the Jobs stage to anything.
4. In a chat, type `/routine <name>` and paste:

```
http://localhost:8765/1-one-page.html
http://localhost:8765/2-two-step.html
http://localhost:8765/3-typeahead.html
http://localhost:8765/4-upload.html
http://localhost:8765/5-skip.html
```

Expected:

| Form | Status |
|---|---|
| 1-one-page | submitted (the page shows SUBMITTED one-page) |
| 2-two-step | submitted |
| 3-typeahead | submitted, with City "Toronto, Ontario, Canada" |
| 4-upload | submitted, with the resume attached; sponsorship "No" follows from the profile for Canada |
| 5-skip | skipped, quoting "U.S. citizenship is required" |

Then run again with a token cap of 1000 in the routine: the first item stops with "token cap reached" and the run pauses on "token cap".
A page that shows "SUBMITTED" for an item reported `ready` is a gate failure.

## R2: handoffs, notes and retries (§17 R2)

`6-account.html` asks for a candidate account with a password before its form. Gaia fills the email, never the password, and hands off. To start it fresh, clear the page's site data (`localStorage` key `accountly`).

**Unattended** (the R2 check). Paste `6-account.html` and `5-skip.html`:

1. 6-account parks as needs you (the account page needs a password), its tab left open. 5-skip is skipped. The run ends done.
2. In that tab, type a password of 8 or more characters and click Create account. The application form shows.
3. On the parked item (the card or the side panel), type a note such as "The account is made; you're signed in." and Save. With "Save to answer bank" ticked, `answers.md` gains the note under the item's question.
4. The run opens again and retries 6-account in the same item chat, in its open tab. Expected: submitted, the page showing SUBMITTED account, and the run done again.

**Attended.** Paste `6-account.html` alone and pick Attended. At the account page the screen edge lights in amber with "Your turn: …", the panel's header turns amber, and Ctrl+Alt+Shift+R is registered. Make the account, then press Ctrl+Alt+Shift+R (or the panel's Resume): the same chat goes on and submits. Left 10 minutes with no input, the item parks and the run moves on.

## R0: the §15 control fixes (GAIA_ROUTINES_HLD.md §3.8)

`7-controls.html` is for a plain Auto chat, not a routine. Its long posting puts the form below the fold. Name and email are prefilled with values the profile contradicts, the phone field formats as you type, 9a and 9b are text boxes with no name under a question, three checkboxes are each named "Yes", and the two enrollment radios have names over 200 characters. Ask Gaia to fill it from `materials/profile.md` without submitting. Expected: every field by name, the names replaced, the Canadian citizen box alone ticked, the first enrollment option, and nothing submitted.

**Tab import.** Open `1-one-page.html` and `2-two-step.html` in Chrome tabs, then press Import open tabs on the launch card: both are listed and ticked, and the tab you were on is selected again afterwards.
