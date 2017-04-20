# Asperalm - Laurent's Aspera Ruby library, including a CLI

Laurent/Aspera/2016

## Overview
This is a Ruby Gem that provides the following features:

* a command line tool: aslmcli
* a FASPManager class for Ruby
* REST and OAuth classes for use with Aspera products APIs

This Gem was developed for the following Purposes:

* show use of (REST) APIs: Node, Files, Shares, Faspex
* provide a command line for some tasks
* cross-platform

Ruby has been chosen as language as it is used in most Aspera products, and the interpret can be found for most platforms.

This gem is provided as-is, and is not intended to be a complete CLI, or industry-grade product. This is a sample.

The CLI's folder where configuration and cache files are kept is `$HOME/.aspera/aslmcli`

Requires Ruby 2.0+

In examples below, command line operations are shown using Bash.

## Quick Start

First, install the gem and its dependencies, this requires Ruby v2.0+, and initialize a configuration file:

```bash
$ gem install asperalm
$ aslmcli config init
```

This creates a dummy configuration file: `$HOME/.aspera/aslmcli/config.yaml`

The use of the configuration file is not mandatory, all parameters can be set on command line, 
but the configuration file provides a way to define default values, especially
for authentication parameters. For Faspex, Shares, Node, Console, only username/password and url is required.

To use the CLI with Aspera Files, a possibility is to do the following (jwt auth):

* Create a private/public key pair, as specified in section: Private/Public Keys

* Register a new application in the Aspera Files Admin GUI (refer to section "Authentication"). Here, as public key, use the contents of a file (generated in step 2): `$HOME/.aspera/aslmcli/filesapikey.pub`

* Edit the file: `$HOME/.aspera/aslmcli/config.yaml`, and set the values in section: files/default for items:
   * url : Your Aspera Files organization URL, e.g. `https://myorg.asperafiles.com`
   * client_id and client_secret : copy from the Application registration form (step 3)
   * username : your username in Aspera Files, e.g. `user@example.com`
   * private_key : location of private key file, leave as `@file:~/.aspera/aslmcli/filesapikey`

* CLI is ready to use:


```bash
$ aslmcli files browse /
:..............................:........:................:...........:......................:..............:
:             name             :  type  : recursive_size :   size    :    modified_time     : access_level :
:..............................:........:................:...........:......................:..............:
: Summer 2016 Training         : link   :                :           : 2016-07-25T15:21:22Z : edit         :
: Laurent Garage SE            : folder : 19316893       :           :                      : edit         :
: Italy Training               : folder : 312068540      :           :                      : edit         :
: Cheese pile.jpeg             : file   :                : 9824      : 2016-11-16T12:10:25Z : edit         :
: Aspera Video                 : folder : 122237276      :           :                      : edit         :
:..............................:........:................:...........:......................:..............:

```

For other applications (Shares, Faspex, ...), authentication is simpler and only require a username and password.


## Usage

```bash
NAME
	aslmcli -- a command line tool for Aspera Applications

SYNOPSIS
	aslmcli COMMANDS [OPTIONS] [ARGS]

COMMANDS
	Supported commands: console, faspex, files, node, shares, config

DESCRIPTION
	Use Aspera application to perform operations on command line.
	OAuth 2.0 is used for authentication in Files, Several authentication methods are provided.

EXAMPLES
	aslmcli files events
	aslmcli --log-level=debug --config-name=myfaspex send 200KB.1
	aslmcli -ntj files set_client_key LA-8RrEjw @file:data/myid

SPECIAL OPTION VALUES
	if an option value begins with @env: or @file:, value is taken from env var or file

OPTIONS (global)
    -h, --help                       Show this message
    -l, --log-level=TYPE             Log level. Values=(debug,info,warn,error,fatal,unknown), current=warn
    -q, --logger=TYPE                log method. Values=(syslog,stdout), current=stdout
        --format=TYPE                output format. Values=(ruby,text), current=text
    -f, --config-file=STRING         read parameters from file in JSON format
    -n, --config-name=STRING         name of configuration in config file
    -r, --rest-debug                 more debug for HTTP calls
```

## Configuration and parameters
All CLI parameters can be provided on command line, but it is more convenient 
to set common parameters (e.g. cedentials) in a configuration file.

The configuration file is a YAML file organized by applications.

For each application type, there is a list of named configurations. The 
configuration named "default" is taken if no "-n" option is provided 
(short for --config-name).

Arguments that require a value can be specified on command line or config file 
with the following specific rules:

* direct value, e.g. --username=foouser
* or, similarly, with @val: --username=@val:foouser
* or a value read from a file: --key=@file:$HOME/.ssh/mykey
* or a value read from a named env var: --password=@env:MYPASSVAR

The default configuration file is: $HOME/.aspera/aslmcli/config.yaml

Here is an example:

```yaml
---
:global:
  default:
    :loglevel: :warn
:files:
  default:
    :auth: :jwt
    :url: https://mycompany.asperafiles.com
    :client_id: <insert client id here>
    :client_secret: <insert client secret here>
    :private_key: "@file:~/.aspera/aslmcli/filesapikey"
    :username: laurent@asperasoft.com
  p:
    :auth: :web
    :url: https://aspera.asperafiles.com
    :client_id: <insert client id here>
    :client_secret: <insert client secret here>
    :redirect_uri: http://local.connectme.us:12345
:faspex:
  default:
    :url: https://10.25.0.3/aspera/faspex
    :username: admin
    :password: MyPassword
:shares:
  default:
    :url: https://10.25.0.6
    :username: admin
    :password: MyPassword
:node:
  default:
    :url: https://10.25.0.8:9092
    :username: node_root
    :password: MyPassword
:console:
  default:
    :url: https://console.asperademo.com/aspera/console
    :username: nyapiuset
    :password: "mypassword"
```
The "default" configuration is taken, but can be overridden on comand line.
Another configuration can be taken with option "-n".

## Learning Aspera Product APIs (REST)

This CLI uses REST APIs.
To display HTTP calls, use argument `-r` or `--rest-debug`, this is useful to display 
exact content or HTTP requests and responses.

In order to get traces of execution, use argument : `--log-level=debug`

## Authentication

### Aspera Faspex / Shares / Console / Node

Only Basic authentication is supported. A "username" and "password" are provided, 
either on command line (--username, --password) or in the configuration file.

### Aspera Files

Aspera Files supports a more powerful and secure authentication mechanism: Oauth. 
HTTP Basic authentication is not supported (deprecated).

With OAuth, the application (aslmcli) must be identified, and a valid Aspera Files 
user must be used to access Aspera Files. Then a "Bearer" token is used for 
HTTP authentication.

First the application (aslmcli) must be declared in the Files GUI 
(see <a href="https://aspera.asperafiles.com/helpcenter/admin/organization/registering-an-api-client">here</a>). By declaring the application, a "client\_id" and "client\_secret" are generated:

<img src="docs/Auth1.png" alt="Files-admin-organization-apiclient-clientdetails"/>

It is possible to use the Aspera Files API, but a web browser is required to generate the token. `aslmcli` will either display the URL to be entered in a local browser, or open a browser directly (various options are proposed).

It is also possible to enable browser-less authentication by using JWT, in this case a private/public key pair is required (see section: Generating a key pair), the public key is provided to Aspera Files:

<img src="docs/Auth2.png" alt="Files-admin-organization-apiclient-authoptions"/>

Upon successful authentication, auth token are saved (cache) in local files, and 
can be used subsequently. Expired token can be refreshed.

## Sample commands

```bash
aslmcli shares browse /
aslmcli shares upload ~/200KB.1 /projectx
aslmcli shares download /projectx/200KB.1 .
aslmcli faspex recv_publink https://myfaspex.myorg.com/aspera/faspex/external_deliveries/78780?passcode=a003aaf2f53e3123456b908525084db6bebc7031
aslmcli -nibm faspex list
aslmcli -nibm faspex recv 05b92393-02b7-4900-ab69-fd56721e896c
aslmcli -nibm faspex --note="my note" --title="my title" --recipient="laurent@asperasoft.com" send ~/200KB.1 
aslmcli console transfers list
aslmcli node browse /
aslmcli node upload ~/200KB.1 /tmp
aslmcli node download /tmp/200KB.1 .
aslmcli files browse /
aslmcli files upload ~/200KB.1 /
aslmcli files download /200KB.1 .
aslmcli files send ~/200KB.1
aslmcli files packages
aslmcli files recv VleoMSrlA
aslmcli files events
aslmcli files usage_reports
```

## Private/Public Keys

In order to use JWT for Aspera Files API client authentication, 
a private/public key pair must be generated.

For example, generate a passphrase-less keypair with `ssh-keygen`:

```bash
$ ssh-keygen -t rsa -f ~/.aspera/aslmcli/filesapikey -N ''
```

One can also use the "openssl" utility:

```bash
$ APIKEY=~/.aspera/aslmcli/filesapikey
$ openssl genrsa -passout pass:dummypassword -out ${APIKEY}.protected 2048
$ openssl rsa -passin pass:dummypassword -in ${APIKEY}.protected -out ${APIKEY}
$ openssl rsa -pubout -in ${APIKEY} -out ${APIKEY}.pub
$ rm -f ${APIKEY}.protected
```


## Contents
Included files are:

<table>
<tr><td><code>lib/asperalm/browser_interaction.rb</code></td><td>for user web login, supports watir or terminal</td></tr>
<tr><td><code>lib/asperalm/cli/*.rb</code></td><td>The CLI itself.</td></tr>
<tr><td><code>lib/asperalm/colors.rb</code></td><td>VT100 colors</td></tr>
<tr><td><code>lib/asperalm/fasp_manager.rb</code></td><td>Ruby FaspManager lib</td></tr>
<tr><td><code>lib/asperalm/oauth.rb</code></td><td>sample oauth</td></tr>
<tr><td><code>lib/asperalm/rest.rb</code></td><td>REST and CRUD support</td></tr>
</table>

## BUGS
This is a sample code only, dont expect full capabilities. This code is not
supported by Aspera.

## TODO
* remove rest and oauth and use ruby standard gems:

  * oauth
  * https://github.com/rest-client/rest-client

use tools from:
http://blog.excelwithcode.com/build-commandline-apps.html

follow:
https://quickleft.com/blog/engineering-lunch-series-step-by-step-guide-to-building-your-first-ruby-gem/

## Contributing

Please contribute: add new functions that use the APIs!
You may contact the author.

