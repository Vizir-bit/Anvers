// Counts the Mullvad relays that could serve a chosen entry and exit, from the relay list the
// app keeps on disk, so that harden.sh can refuse a choice no relay can satisfy. With lockdown
// mode on, an unsatisfiable choice would otherwise leave the Mac without any network.
//
// Run by harden.sh through macOS's JavaScript for Automation:
//   osascript -l JavaScript relay-check.js <relays.json> <entry> <exit> <obfuscation> <owned>
// <entry> and <exit> are two-letter country codes, or "-" to skip that count.
// <owned> is "yes" to count only Mullvad-owned exit relays.
// Prints "entry=<n> exit=<n>".
//
// The rules mirror Mullvad's relay selector at release 2026.5: in a multihop connection DAITA
// and the obfuscation method constrain the entry relay; location and ownership constrain the exit.

function hasFeature(relay, name) {
    return !!(relay.features && Object.prototype.hasOwnProperty.call(relay.features, name));
}

function countryOf(relay) {
    return String(relay.location || '').split('-')[0];
}

function selectableByCountry(relay) {
    return relay.active === true && relay.include_in_country !== false;
}

function count(list, entry, exit, obfuscation, ownedOnly) {
    var relays = (list && list.wireguard && list.wireguard.relays) || [];
    var n = { entry: 0, exit: 0 };
    relays.forEach(function (relay) {
        if (!selectableByCountry(relay)) {
            return;
        }
        var cc = countryOf(relay);
        var daita = hasFeature(relay, 'daita') || relay.daita === true;
        if (entry !== '-' && cc === entry && daita &&
            (obfuscation !== 'quic' || hasFeature(relay, 'quic')) &&
            (obfuscation !== 'lwo' || hasFeature(relay, 'lwo'))) {
            n.entry++;
        }
        if (exit !== '-' && cc === exit && (!ownedOnly || relay.owned === true)) {
            n.exit++;
        }
    });
    return n;
}

function readText(path) {
    if (typeof ObjC !== 'undefined') {
        ObjC.import('Foundation');
        var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, $());
        if (text.isNil()) {
            throw new Error('cannot read ' + path);
        }
        return text.js;
    }
    return require('fs').readFileSync(path, 'utf8');
}

function run(argv) {
    var list = JSON.parse(readText(argv[0]));
    var n = count(list, argv[1], argv[2], argv[3], argv[4] === 'yes');
    return 'entry=' + n.entry + ' exit=' + n.exit;
}

// Lets the test suite load this file under Node; ignored by osascript.
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { run: run, count: count };
}
