function testing {
    param(
        $computername 
    )
    Write-Host 'Hello'
    try {
        test-netconnection -computername $computername -CommonTcpPort HTTP
        write-verbose 'success'
    }
    catch {
        write-verbose 'fail'
        throw        
    }
}
