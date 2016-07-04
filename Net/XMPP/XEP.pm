
package Net::XMPP::XEP;

use Net::XMPP::Namespaces;

$Net::XMPP::Namespaces::SKIPNS{'__netxmpp__'} = 1;

#-----------------------------------------------------------------------------
# jabber:x:data
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => 'jabber:x:data',
            tag   => 'x',
            xpath => {
                      Field        => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field' },
                                       calls => [ 'Add' ],
                                      },
                      Fields       => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field', },
                                      },
                      Form         => { path => '@form' },
                      Instructions => { path => 'instructions/text()' },
                      Item         => {
                                       type  => 'child',
                                       path  => 'item',
                                       child => { ns => '__netxmpp__:x:data:item' },
                                       calls => [ 'Add' ],
                                      },
                      Items        => {
                                       type  => 'child',
                                       path  => 'item',
                                       child => { ns => '__netxmpp__:x:data:item', },
                                      },
                      Reported     => {
                                       type  => 'child',
                                       path  => 'reported',
                                       child => { ns => '__netxmpp__:x:data:reported' },
                                       calls => [ 'Get', 'Defined', 'Add', 'Remove' ],
                                      },
                      Title        => { path => 'title/text()' },
                      Type         => { path => '@type' },
                      Data         => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                     },
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:x:data:field
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:x:data:field',
            xpath => {
                      Desc     => { path => 'desc/text()' },
                      Label    => { path => '@label' },
                      Option   => {
                                   type  => 'child',
                                   path  => 'option',
                                   child => { ns => '__netxmpp__:x:data:field:option' },
                                   calls => [ 'Add' ],
                                  },
                      Options  => {
                                   type  => 'child',
                                   path  => 'option',
                                   child => { ns => '__netxmpp__:x:data:field:option', },
                                  },
                      Required => {
                                   type => 'flag',
                                   path => 'required',
                                  },
                      Type     => { path => '@type' },
                      Value    => {
                                   type => 'array',
                                   path => 'value/text()',
                                  },
                      Var      => { path => '@var' },
                      Field  => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'jabber:x:data - field objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:x:data:field:option
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:x:data:field:option',
            xpath => {
                      Label  => { path => '@label' },
                      Value  => { path => 'value/text()' },
                      Option => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'jabber:x:data - option objects',
                     },
           );
}
       
#-----------------------------------------------------------------------------
# __netxmpp__:x:data:item
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:x:data:item',
            xpath => {
                      Field        => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field' },
                                       calls => [ 'Add' ],
                                      },
                      Fields       => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field', },
                                      },
                      Item         => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'jabber:x:data - item objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:x:data:reported
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:x:data:reported',
            xpath => {
                      Field        => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field' },
                                       calls => [ 'Add' ],
                                      },
                      Fields       => {
                                       type  => 'child',
                                       path  => 'field',
                                       child => { ns => '__netxmpp__:x:data:field', },
                                      },
                      Reported     => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'jabber:x:data - reported objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# http://jabber.org/protocol/commands
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => 'http://jabber.org/protocol/commands',
            tag   => 'command',
            xpath => {
                      Action       => { path => '@action' },
                      FormAction   => {
                                       type  => 'child',
                                       path  => 'actions',
                                       child => { ns => '__netxmpp__:iq:commands:actions' },
                                       calls => [ 'Add' ],
                                      },
                      FormActions  => {
                                       type  => 'child',
                                       path  => 'actions',
                                       child => { ns => '__netxmpp__:iq:commands:actions' },
                                      },
                      Form         => {
                                       type  => 'child',
                                       path  => 'x',
                                       child => { ns => 'jabber:x:data' },
                                       calls => [ 'Add' ],
                                      },
                      Forms        => {
                                       type  => 'child',
                                       path  => 'x',
                                       child => { ns => 'jabber:x:data' }
                                      },
                      Node         => { path => '@node' },
                      Note         => {
                                       type  => 'child',
                                       path  => 'note',
                                       child => { ns  => '__netxmpp__:iq:commands:note' },
                                       calls => [ 'Add' ],
                                      },
                      Notes        => {
                                       type  => 'child',
                                       path  => 'note',
                                       child => { ns => '__netxmpp__:iq:commands:note', },
                                      },
                      SessionID    => { path => '@sessionid' },
                      Status       => { path => '@status' },
                      Command      => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                     },
           );
}

# xxx xml:lang

#-----------------------------------------------------------------------------
# __netxmpp__:iq:commands:actions
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:iq:commands:actions',
            xpath => {
                      Prev     => {
                                   type  => 'flag',
                                   path  => 'prev'
                                  },
                      Next     => {
                                   type  => 'flag',
                                   path  => 'next'
                                  },
                      Complete => {
                                   type  => 'flag',
                                   path  => 'complete'
                                  },
                      Execute  => { path => '@execute'}
                     },
            docs  => {
                      module => 'Net::XMPP::XEP'
                     }
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:iq:commands:note
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:iq:commands:note',
            xpath => {
                      Type    => { path => '@type' },
                      Message => { path => 'text()' },
                      Note    => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'http://jabber.org/protocol/commands - note objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# http://jabber.org/protocol/disco#info
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => 'http://jabber.org/protocol/disco#info',
            tag   => 'query',
            xpath => {
                      Feature    => {
                                     type  => 'child',
                                     path  => 'feature',
                                     child => { ns => '__netxmpp__:iq:disco:info:feature' },
                                     calls => [ 'Add' ],
                                    },
                      Features   => {
                                     type  => 'child',
                                     path  => 'feature',
                                     child => { ns => '__netxmpp__:iq:disco:info:feature' },
                                    },
                      Identity   => {
                                     type  => 'child',
                                     path  => 'identity',
                                     child => { ns => '__netxmpp__:iq:disco:info:identity' },
                                     calls => [ 'Add' ],
                                    },
                      Identities => {
                                     type  => 'child',
                                     path  => 'identity',
                                     child => { ns => '__netxmpp__:iq:disco:info:identity' },
                                    },
                      Node       => { path => '@node' },
                      DiscoInfo  => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                     },
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:iq:disco:info:feature
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:iq:disco:info:feature',
            xpath => {
                      Var     => { path => '@var' },
                      Feature => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'http://jabber.org/protocol/disco#info - feature objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# __netxmpp__:iq:disco:info:identity
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:iq:disco:info:identity',
            xpath => {
                      Category => { path => '@category' },
                      Name     => { path => '@name' },
                      Type     => { path => '@type' },
                      Identity => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'http://jabber.org/protocol/disco#info - identity objects',
                     },
           );
}

#-----------------------------------------------------------------------------
# http://jabber.org/protocol/disco#items
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => 'http://jabber.org/protocol/disco#items',
            tag   => 'query',
            xpath => {
                      Item       => {
                                     type  => 'child',
                                     path  => 'item',
                                     child => { ns => '__netxmpp__:iq:disco:items:item' },
                                     calls => [ 'Add' ],
                                    },
                      Items      => {
                                     type  => 'child',
                                     path  => 'item',
                                     child => { ns => '__netxmpp__:iq:disco:items:item' },
                                    },
                      Node       => { path => '@node' },
                      DiscoItems => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                     },
           );
}
       
#-----------------------------------------------------------------------------
# __netxmpp__:iq:disco:items:item
#-----------------------------------------------------------------------------
{
    &Net::XMPP::Namespaces::add_ns(
        ns    => '__netxmpp__:iq:disco:items:item',
            xpath => {
                      Action => { path => '@action' },
                      JID    => {
                                 type => 'jid',
                                 path => '@jid',
                                },
                      Name   => { path => '@name' },
                      Node   => { path => '@node' },
                      Item   => { type => 'master' },
                     },
            docs  => {
                      module => 'Net::XMPP::XEP',
                      name   => 'http://jabber.org/protocol/disco#items - item objects',
                     },
           );
}
