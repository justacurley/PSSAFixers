function testing {
    param(
        $uri 
    )
    Write-Host 'Hello'
    try {
        invoke-restmethod -Method Get -uri $uri -erroraction stop 
        write-verbose 'success'
    }
    catch {
        write-verbose 'fail'        
    }
}
