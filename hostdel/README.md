# hostdel.com theme speed fixes (WHMCS server `secure`, 5.78.77.128) — 2026-10-16

Theme: `/home/hostdel/public_html/templates/hostdelnew/`. Changes made on the live server by the owner,
one command at a time. Measured from the built-in browser (public pages, signed out).

Baseline before these fixes: `/login` first byte 0.43 s on the server itself, 0.84–1.5 s through Cloudflare;
90 requests; 3 s to DOMContentLoaded even with a warm cache.

## 1. AngularJS only on the SMS marketing page — DONE

AngularJS 1.2.16 (2014, end of life) was loaded render-blocking on every page by
`includes/head.tpl` line 17, but only `/sms-marketing.php` uses it (`header.tpl` already switches
`ng-app="smsSplitApp"` on with `{if $filename eq 'sms-marketing'}`; that page also loads its own
`js/smssplit.js`). None of the six hostdel.com scripts on other pages reference `angular`.

`includes/head.tpl` line 17 (file uses CRLF line endings):

- before: `<script src="//ajax.googleapis.com/ajax/libs/angularjs/1.2.16/angular.min.js"></script>`
- after:  `{if $filename eq "sms-marketing"}<script src="//ajax.googleapis.com/ajax/libs/angularjs/1.2.16/angular.min.js"></script>{/if}`

Backup: `/root/head.tpl.before-angular-scope` (copied with `cp -p` before the edit).
The first `sed` attempt matched nothing because the line ends in `\r`; the second matched `\r$` and kept it.

Verified (browser): AngularJS gone from /login, /, /cart.php, /contact.php, knowledgebase; still on
/sms-marketing.php with `ng-app`, AngularJS bootstraps (30 scopes) and the SMS splitter produced a segment
from typed text; no script errors on either page; no Smarty tags leaked into the HTML.

To undo: copy the backup back over `includes/head.tpl` (keep owner `hostdel:hostdel`).

## 2. Missing Lightbox images — DONE

`css/all.min.css` (Lightbox2 styles) preloads `../images/close.png`, `loading.gif`, `prev.png`, `next.png`
on every page (`body::after`). The folder `templates/hostdelnew/images/` did not exist, so every page view
triggered four 404s, and each 404 was a full WHMCS page: 88 KB, ~0.7 s, PHP, `BYPASS`/`private` (never cached).
The identical files ship with the stock theme in `templates/twenty-one/images/` (also `six/images/`):
close.png 280 B, loading.gif 8476 B, next.png 1350 B, prev.png 1360 B.

Commands run:

    install -d -o hostdel -g hostdel -m 755 /home/hostdel/public_html/templates/hostdelnew/images
    install -o hostdel -g hostdel -m 644 /home/hostdel/public_html/templates/twenty-one/images/{close.png,loading.gif,prev.png,next.png} /home/hostdel/public_html/templates/hostdelnew/images/

(the real command listed the four files one by one.) Verified: all four return 200 with the right type and
size, `public, max-age=28800`; a fresh /login load shows no 4xx responses at all.

To undo: delete the four files and the empty `images` folder (nothing else uses it).

## Result after 1 + 2 (one warm reload of /login, so indicative only)

DOMContentLoaded 1.8 s (was 3.0 s), full load 2.4 s (was 6.2 s), 86 requests (was 90), no 404s.
Per page view the server now renders one WHMCS page instead of five.

## Still open (not done)

- Font Awesome loaded three times (`fonta/css/all.min.css`, `assets/css/fontawesome-all.min.css`,
  `html/css/font-awesome.min.css` v4) and `css/all.min.css?v=dfb8a3` linked twice; > 1.3 MB of icon fonts.
- Logo `html/img/HostDel-logo-white-bg.gif` 359 KB (700x145 shown at 140x36).
- Render-blocking head scripts: tawk.to, Google Translate, `js/scripts.min.js` (616 KB).
- Cloudflare: `js/scripts.min.js` is `private`/BYPASS; static files only `max-age=28800` despite `?v=`.
- `ng-app` sits on `<html>` on the SMS page, so the whole page is an AngularJS 1.2 template; moving it to the
  calculator's container would remove the old-AngularJS template-injection surface there.
