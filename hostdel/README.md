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

## Runbook for the open items — 2026-10-17 (not yet run)

Same rules as before: `cp -p` a backup to `/root/` first, remember `head.tpl`/`header.tpl` use CRLF (`\r$` in sed),
keep owner `hostdel:hostdel`, check one page in the browser after each step, and bump `?v=` where one exists.
`T=/home/hostdel/public_html/templates/hostdelnew` throughout. Do them in the order below (biggest, safest first).

### 3. Font Awesome loaded three times / Lightbox CSS linked twice

Find every stylesheet link in the head first; the second `css/all.min.css?v=dfb8a3` is a plain duplicate and goes
regardless. Which of the two Font Awesome 5 copies to keep depends on their version:

    grep -n 'stylesheet' $T/includes/head.tpl
    head -c 300 $T/fonta/css/all.min.css; echo
    head -c 300 $T/assets/css/fontawesome-all.min.css; echo
    head -c 300 $T/html/css/font-awesome.min.css; echo
    ls -la $T/fonta/webfonts $T/assets/webfonts 2>/dev/null

Keep the newer of the two FA5 files (the header comment says `Font Awesome Free 5.x.y`), remove the other link.
Do NOT drop the v4 file (`html/css/font-awesome.min.css`) yet: FA5 renamed icons (`fa-envelope-o`,
`fa-file-text`, `fa-user-o`, ...). Check whether any template still uses v4-only names:

    grep -rhoE 'fa fa-[a-z0-9-]+' $T --include=*.tpl | sort | uniq -c | sort -rn | head -40

If that list is empty or only has names that exist in FA5, remove the v4 link too; otherwise replace it with FA5's
`v4-shims.min.css` (ships next to `all.min.css` in the FA5 download, ~30 KB vs 1.3 MB of fonts).

    cp -p $T/includes/head.tpl /root/head.tpl.before-fa-dedupe
    # one sed per link to drop; confirm each with grep -n before running it, e.g.:
    sed -i '/assets\/css\/fontawesome-all\.min\.css/d' $T/includes/head.tpl
    grep -n 'stylesheet' $T/includes/head.tpl      # expect: one FA5 line, one css/all.min.css line

Verify: icons on /login, /, /cart.php, /contact.php, the client-area sidebar (signed in) and the footer social
icons all render; browser network panel shows one Font Awesome CSS and one set of `.woff2` files.
Undo: copy `/root/head.tpl.before-fa-dedupe` back.

### 4. Logo 359 KB GIF shown at 140x36

Two options. (a) keeps the `.gif` name so no template changes; (b) is smaller still but needs the header edited.

    grep -rn 'HostDel-logo-white-bg' $T --include=*.tpl
    cp -p $T/html/img/HostDel-logo-white-bg.gif /root/HostDel-logo-white-bg.gif.orig
    identify $T/html/img/HostDel-logo-white-bg.gif      # ImageMagick; expect 700x145

    # (a) in place: 2x the display size, keep GIF
    convert /root/HostDel-logo-white-bg.gif.orig -coalesce -resize 280x58 -strip -colors 64 \
        $T/html/img/HostDel-logo-white-bg.gif
    chown hostdel:hostdel $T/html/img/HostDel-logo-white-bg.gif
    ls -la $T/html/img/HostDel-logo-white-bg.gif       # expect well under 20 KB

    # (b) PNG with transparency, then point the template(s) from the grep above at it
    convert /root/HostDel-logo-white-bg.gif.orig -coalesce -resize 280x58 -strip \
        $T/html/img/HostDel-logo-white-bg.png
    chown hostdel:hostdel $T/html/img/HostDel-logo-white-bg.png
    cp -p $T/includes/header.tpl /root/header.tpl.before-logo
    sed -i 's/HostDel-logo-white-bg\.gif/HostDel-logo-white-bg.png/g' $T/includes/header.tpl

If `convert` is missing: `dnf install -y ImageMagick` (or resize it locally and `scp` it up).
Verify: logo crisp on a retina/2x screen, correct size on mobile; email templates in WHMCS admin may reference the
same GIF by full URL — leave the original in place under the `.orig` name if (b) and they do.
Undo: copy the `.orig` back over the `.gif` (and `header.tpl` backup for (b)).

### 5. Render-blocking scripts in `<head>`

Show them first:

    grep -n '<script' $T/includes/head.tpl $T/includes/header.tpl

- **tawk.to**: its official snippet is already `async` and belongs at the end of `footer.tpl`, not the head. Cut the
  block from `head.tpl` and paste it just before `</body>` in `footer.tpl` (or into WHMCS Admin → Setup → General
  → the footer-output hook). No functional change, chat loads after content.
- **Google Translate**: add `defer` to the `translate.google.com/translate_a/element.js?cb=...` tag and make sure
  the `googleTranslateElementInit` function is defined in an inline script *above* it (it must exist when the
  callback fires). The widget then initialises after parse instead of blocking it.
- **`js/scripts.min.js` (616 KB)**: most likely contains jQuery. `defer` is safe only if nothing inline in the body
  calls `$`/`jQuery` before `DOMContentLoaded`. Check:

        grep -rn --include=*.tpl -E '\$\(|jQuery\(' $T | grep -v 'scripts.min.js' | head
        grep -c 'jQuery' $T/js/scripts.min.js

  If the inline uses are all wrapped in `$(document).ready`/`$(function(){...})` they still break under `defer`
  (the symbol `$` is undefined at parse time). Either (1) move the tag to the end of `footer.tpl` *above* those
  inline scripts, or (2) keep it in the head but split it: WHMCS already loads its own jQuery from
  `/assets/js/jquery.min.js`; find out what else is in the bundle (`grep -o '/\*![^*]*\*/' $T/js/scripts.min.js`
  lists library headers) and drop the duplicates. Option (1) is the one-line change:

        cp -p $T/includes/head.tpl /root/head.tpl.before-scripts-move
        cp -p $T/includes/footer.tpl /root/footer.tpl.before-scripts-move
        # cut the <script src="...js/scripts.min.js..."> line from head.tpl, paste it in footer.tpl before the
        # first inline <script> that uses $ (sed -n '/scripts.min.js/p' head.tpl shows the exact line to move)

Verify after each move: no red errors in the browser console on /login, /, /cart.php, /sms-marketing.php, the
client area; menus, dropdowns, the cart steps and the SMS splitter still work. Undo: restore the two backups.

### 6. Cloudflare / origin caching

First see what the origin itself sends, bypassing Cloudflare:

    curl -sI --resolve hostdel.com:443:5.78.77.128 https://hostdel.com/templates/hostdelnew/js/scripts.min.js \
        | grep -iE '^(HTTP|cache-control|expires|set-cookie|x-powered-by)'
    curl -sI --resolve hostdel.com:443:5.78.77.128 https://hostdel.com/templates/hostdelnew/css/all.min.css \
        | grep -iE '^(HTTP|cache-control|expires)'

`private` on a plain `.js` means either an `.htaccess`/server rule or the request being routed through PHP:

    grep -rn -iE 'Cache-Control|ExpiresByType|private' /home/hostdel/public_html/.htaccess $T/.htaccess 2>/dev/null
    grep -rn 'scripts.min.js' /home/hostdel/public_html/.htaccess $T/.htaccess 2>/dev/null

Fix at the origin (Apache/LiteSpeed, `mod_headers` + `mod_expires`): add to `$T/.htaccess` (create it, owner
`hostdel:hostdel`, mode 644):

    <IfModule mod_headers.c>
      <FilesMatch "\.(css|js|png|gif|jpe?g|svg|woff2?|ttf|eot)$">
        Header set Cache-Control "public, max-age=2592000"
        Header unset Set-Cookie
      </FilesMatch>
    </IfModule>

30 days, not a year, because `js/scripts.min.js` and the logo carry no `?v=` — add `?v=<date>` to those links in
the templates and the value can go to `max-age=31536000, immutable` later. Then on Cloudflare: Caching → Cache
Rules → new rule, `URI Path starts with /templates/hostdelnew/`, Cache eligible, Edge TTL "Override origin"
1 month, Browser TTL "Respect origin". Purge `/templates/hostdelnew/*` once.
Verify through Cloudflare: `cf-cache-status: HIT` on the second request, `cache-control: public, max-age=2592000`.
Undo: delete the `.htaccess` block and the Cloudflare rule.

### 7. `ng-app` on `<html>` on the SMS page

`header.tpl` puts `ng-app="smsSplitApp"` on the `<html>` tag, so every `{{ ... }}` anywhere in that page — including
user-supplied text echoed by WHMCS — is evaluated by AngularJS 1.2 (client-side template injection). Move it to the
calculator's container.

    grep -n 'ng-app' $T/includes/header.tpl $T/sms-marketing.tpl
    grep -n 'ng-' $T/sms-marketing.tpl | head -40          # everything ng-* must be inside one container

Pick the outermost element that wraps all `ng-controller`/`ng-model`/`ng-click` uses (usually the `<div>` around
the textarea and counters). Then:

    cp -p $T/includes/header.tpl /root/header.tpl.before-ngapp
    cp -p $T/sms-marketing.tpl /root/sms-marketing.tpl.before-ngapp
    sed -i 's/{if \$filename eq .sms-marketing.} ng-app="smsSplitApp"{\/if}//' $T/includes/header.tpl
    grep -n 'ng-app' $T/includes/header.tpl             # expect nothing
    # in sms-marketing.tpl add  ng-app="smsSplitApp"  to that container's opening tag (one sed on its exact line)

Verify: /sms-marketing.php still bootstraps (type text, segment count updates); view source of `<html>` has no
`ng-app`; `{{1+1}}` typed into the site search / a knowledgebase query on that page shows literally, not `2`.
Undo: restore the two backups.
