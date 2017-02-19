#!/usr/local/bin/tclsh8.6
#
package require base64
package require http 2
package require tls
package require tdom

::http::register https 443 ::tls::socket

proc get_option {param} {
    expr {[lsearch $::argv "-$param"] != -1}
}

proc get_param {param} {
    set idx [lsearch $::argv "-$param"]
    if {$idx != -1} {
        return [lindex $::argv $idx+1]
    } else {
        return {}
    }
}

proc get_param_or_query {param msg {echo on}} {
    set txt [get_param $param]
    if {$txt eq {}} {
        if {[string is false -strict $echo]} {
            set stty_save [exec stty -g]
            exec stty -echo
        }
        puts -nonewline stderr "$msg: "
        flush stderr
        gets stdin txt
        if {[string is false -strict $echo]} {
            exec stty $stty_save
            puts stderr {}
        }
    }
    return $txt
}

set url  [get_param_or_query url "URL"]
set user [get_param_or_query user "Username"]
set pass [get_param_or_query pass "Password" off]
set search [get_param_or_query search "Search"]

proc report_headers {} {
    list Authorization "Basic [base64::encode ${::user}:${::pass}]" \
         Depth 1 Content-type {application/xml}
}

proc report_query {txt} {
    # <C:address-data content-type="application/vcard+json">
    set query {
        <C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
            <D:prop>
                <C:address-data content-type="text/vcard">
                    <C:prop name="NICKNAME"/>
                    <C:prop name="EMAIL"/>
                    <C:prop name="FN"/>
                </C:address-data>
            </D:prop>
            <C:filter test="anyof">
                <C:prop-filter name="FN">
                    <C:text-match collation="i;unicode-casemap" match-type="contains" >@TEXT@</C:text-match>
                </C:prop-filter>
                <C:prop-filter name="EMAIL">
                    <C:text-match collation="i;unicode-casemap" match-type="contains" >@TEXT@</C:text-match>
                </C:prop-filter>
                <C:prop-filter name="NICKNAME">
                    <C:text-match collation="i;unicode-casemap" match-type="contains" >@TEXT@</C:text-match>
                </C:prop-filter>
            </C:filter>
        </C:addressbook-query>
    }
    string map [list @TEXT@ $txt] $query
}

proc report {txt} {
    set tok [::http::geturl $::url \
        -method REPORT \
        -headers [report_headers] \
        -query [report_query $txt] \
        -keepalive true]
    set data [::http::data $tok]
    ::http::cleanup $tok
    set data
}

proc vcards {txt} {
    set xml [report $txt]
    dom parse $xml doc
    $doc documentElement root
    set vcards [list]
    set ns {d DAV: card urn:ietf:params:xml:ns:carddav}
    foreach node [$root selectNodes -namespaces $ns {/d:multistatus/d:response/d:propstat/d:prop/card:address-data}] {
        lappend vcards [$node text]
    }
    set vcards
}

proc vcard2list {vcard} {
    # Fix end of lines
    set vcard [string map {"\r\n" "\n"} $vcard]

    # Split into lines, skip empty ones
    set lines [split $vcard "\n"]
    set lines [lmap l $lines {if {$l eq {}} { continue } { set l }}]

    # Check first and end line
    if {[lindex $lines 0] ne {BEGIN:VCARD} || [lindex $lines end] ne {END:VCARD}} {
        puts "Invalid vcard lines: $lines"
    }

    # Unfold continuation lines
    for {set i 0} {$i < [llength $lines]} {incr i} {
        set line [lindex $lines $i]
        if {[regexp {^[[:space:]]} $line]} {
            incr i -1
            lset lines $i "[lindex $lines $i][string trimleft $line]"
            set lines [lreplace $lines $i+1 $i+1]
        }
    }

    set lines
}

proc vcardline_regexp {name} {
    # This matches any content line and returns
    # . group
    # . parameters
    # . value
    #
    # TODO - handle escapes
    return "^(.*\.)?${name}(;.*)*:(.*)$"
}

proc to_mutt {txt} {
    set verbose [get_option verbose]
    set entries [list]
    foreach vcard [vcards $txt] {
        set lines [vcard2list $vcard]
        set fn [lsearch -inline -regexp $lines {^(.*\.)?FN}]
        set nn [lsearch -inline -regexp $lines {^(.*\.)?NICKNAME}]
        set emails [lsearch -inline -all -regexp $lines {^(.*\.)?EMAIL}]
        if {$fn eq {} || $emails eq {}} {
            continue
        }

        # FN element
        regexp -nocase [vcardline_regexp FN] $fn _ fn_group fn_params fn_value

        # NICKNAME element
        if {[regexp -nocase [vcardline_regexp NICKNAME] $nn _ nn_group nn_params nn_value]} {
            append fn_value " ($nn_value)"
        }

        foreach email $emails {
            # EMAIL elements
            regexp -nocase [vcardline_regexp EMAIL] $email _ email_group email_params email_value
            set params [split $email_params {;=}]
            set type {}
            if {[set idx [lsearch $params TYPE]] != -1} {
                set type [lindex $params $idx+1]
            }
            lappend entries [list $email_value $fn_value $type]
        }

        if {$verbose} {
            puts $vcard
        }

    }

    set out {}
    foreach e [lsort -index 1 $entries] {
        append out [join $e "\t"] "\n"
    }
    set out
}

puts ""
puts [to_mutt $search]
