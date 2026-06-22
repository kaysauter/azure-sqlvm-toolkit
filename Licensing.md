# Licensing

AzureSqlVmToolkit does not grant SQL Server, Windows Server, Azure, or third-party licenses. The toolkit only helps create Azure resources and run setup scripts.

> [!CAUTION]
> This page is only a reminder for AzureSqlVmToolkit users. If anything here differs from Microsoft Product Terms, Microsoft Learn, your agreement, or guidance from your licensing representative, the Microsoft source is definitive.

> [!CAUTION]
> As of May 2026, the full SQL Server edition used by the toolkit default image is free only for non-production development and test use. Production SQL Server workloads must use a valid paid or otherwise approved Microsoft licensing path. Do not treat the toolkit default as a free production SQL Server license.

## Toolkit default

The default VM image is:

```yaml
vm:
  image:
    publisherName: "MicrosoftSQLServer"
    offer: "sql2022-ws2022"
    skus: "sqldev-gen2"
    version: "latest"
```

That is a SQL Server Developer image on Windows Server. Use it for demos, labs, learning, development, and test scenarios only unless your own licensing review says otherwise.

Production SQL Server on Azure VM usually needs one of these licensing paths:

- a pay-as-you-go SQL Server image where SQL Server licensing is included in VM runtime billing
- Azure Hybrid Benefit with eligible licenses and active Software Assurance or qualifying subscription rights
- another Microsoft-approved licensing path for your agreement and workload

## Free editions

Microsoft currently documents SQL Server Developer as free for non-production development and testing. Microsoft also documents SQL Server Express as a free, limited edition for lightweight desktop, web, and small server applications.

Do not generalize from those free editions to Standard, Enterprise, Web, or production SQL Server workloads. Use the Microsoft pages below for the current rules, edition limits, and billing behavior.

## Microsoft references

- [Microsoft Product Terms](https://www.microsoft.com/licensing/terms/productoffering/MicrosoftAzureServices/EAEAS)
- [SQL Server Licensing Resources and Documents](https://www.microsoft.com/licensing/docs/view/SQL-Server)
- [SQL Server downloads](https://www.microsoft.com/en-us/sql-server/sql-server-downloads)
- [SQL Server 2022 editions and supported features](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022?view=sql-server-ver16)
- [SQL Server on Azure VM overview](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-on-azure-vm-iaas-what-is-overview?view=azuresql)
- [SQL Server on Azure VM FAQ](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/frequently-asked-questions-faq?view=azuresql)
- [Change the license model for a SQL VM in Azure](https://learn.microsoft.com/azure/virtual-machines/windows/sql/virtual-machines-windows-sql-ahb)

## Practical checklist

Before using a deployment for anything beyond a disposable lab, confirm the SQL Server edition is allowed for the workload, the Azure VM SQL license type is correct, Azure Hybrid Benefit is only used when eligible, and your organization has documented who approved the licensing model.
