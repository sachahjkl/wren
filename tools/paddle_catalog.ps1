# Creates Wren's Paddle catalog: one product, "Wren User Licence", with one one-time price of 29 EUR, taxes included.
# See docs/licence.md ("Paddle sandbox"). Dry run by default: it prints what it would send and sends nothing.
#   $env:PADDLE_API_KEY = '<a server-side key with product.read/write and price.read/write>'   # not saved anywhere
#   powershell -File tools\paddle_catalog.ps1                          # dry run
#   powershell -File tools\paddle_catalog.ps1 -Apply                   # sandbox (the default environment)
#   powershell -File tools\paddle_catalog.ps1 -Apply -Environment live
# Safe to run again: a product with this name, and a price with this amount on it, are reused, not duplicated.
# Revoke the key in Paddle (Developer tools > Authentication) once the ids are noted: the Worker needs a different key
# (customer.read only).
param(
    [switch]$Apply,
    [ValidateSet('sandbox', 'live')][string]$Environment = 'sandbox',
    [string]$ProductName = 'Wren User Licence',
    [string]$Amount = '2900',        # lowest denomination, as a string: 29.00 EUR is "2900"
    [string]$Currency = 'EUR'
)
$ErrorActionPreference = 'Stop'
$base = if ($Environment -eq 'live') { 'https://api.paddle.com' } else { 'https://sandbox-api.paddle.com' }

$product = [ordered]@{
    name         = $ProductName
    tax_category = 'standard'
    description  = 'Personal, perpetual licence for Wren, with two years of updates from the 1.0 release. Wren is free during the beta.'
}
$price = [ordered]@{
    description  = 'Wren User Licence, one payment, taxes included'
    name         = 'One payment'
    unit_price   = [ordered]@{ amount = $Amount; currency_code = $Currency }
    tax_mode     = 'internal'                     # the buyer pays the displayed price: tax is included in it
    quantity     = [ordered]@{ minimum = 1; maximum = 1 }
    # no billing_cycle (one-time), no trial_period, no unit_price_overrides (Paddle converts for other countries)
}

if (-not $Apply) {
    "DRY RUN ($Environment, $base): nothing is sent. Add -Apply to create it."
    "POST /products"; $product | ConvertTo-Json -Depth 5
    "POST /prices (product_id: the product above)"; $price | ConvertTo-Json -Depth 5
    return
}

$key = $env:PADDLE_API_KEY
if (-not $key) { throw 'Set $env:PADDLE_API_KEY to a server-side API key of the ' + $Environment + ' account first.' }
$h = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }

function Call($method, $path, $body) {
    $args2 = @{ Method = $method; Uri = "$base$path"; Headers = $h }
    if ($body) { $args2.Body = ($body | ConvertTo-Json -Depth 8) }
    try { return Invoke-RestMethod @args2 } catch {
        $msg = $_.ErrorDetails.Message
        throw "Paddle answered an error to $method $path : $msg"
    }
}

# the product: reused when one of this name is already there
$found = (Call 'GET' '/products?status=active&per_page=200' $null).data | Where-Object { $_.name -eq $ProductName } | Select-Object -First 1
if ($found) { $pid2 = $found.id; "product exists: $pid2" } else {
    $pid2 = (Call 'POST' '/products' $product).data.id; "product created: $pid2"
}

# the price: reused when this product already has one of this amount and no billing cycle
$prices = (Call 'GET' "/prices?product_id=$pid2&status=active&per_page=200" $null).data
$same = $prices | Where-Object { $_.unit_price.amount -eq $Amount -and $_.unit_price.currency_code -eq $Currency -and -not $_.billing_cycle } | Select-Object -First 1
if ($same) { $price_id = $same.id; "price exists: $price_id" } else {
    $price.product_id = $pid2
    $price_id = (Call 'POST' '/prices' $price).data.id; "price created: $price_id"
}

""
"Environment : $Environment"
"Product     : $ProductName  $pid2"
"Price       : $Amount $Currency, one-time, tax included, quantity 1  $price_id"
""
"Next: PRICE_SUPPORTER = $price_id in licence/worker/cloudflare.config.ts and wrangler.jsonc (the right environment),"
"      data-price-supporter = $price_id in site/pricing/index.html."
