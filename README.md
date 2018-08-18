# Starling Export

A quick a and simple way to get Starling transactions into QIF and CSV files.

This is a fork of the original script from <https://github.com/scottrobertson/starling-export> and modified to use the new and as yet still unstable v2 of the API so richer information can be gathered with fewer API calls.

It also implements custom mappings for categories and the "number" field that fit my usage within Banktivity.

### How to use:

```
ruby starling-export.rb qif --access_token=#{access_token}
ruby starling-export.rb csv --access_token=#{access_token}
```

### access_token

Get a token from here https://developer.starlingbank.com/token/list
