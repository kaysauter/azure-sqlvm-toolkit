// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://kaysauter.github.io',
	base: '/azure-sqlvm-toolkit',
	integrations: [
		starlight({
			title: 'AzureSqlVmToolkit',
			description: 'Beginner-friendly Azure SQL Server VM deployments with security-minded defaults.',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/kaysauter/azure-sqlvm-toolkit' }],
			components: {
				ThemeProvider: './src/components/ThemeProvider.astro',
				ThemeSelect: './src/components/ThemeSelect.astro',
			},
			sidebar: [
				{
					label: 'Start Here',
					items: [
						{ label: 'Why using AzSQLVMKit', slug: 'why-using-azuresqlvmtoolkit' },
						{ label: 'Overview', slug: 'overview' },
						{ label: 'AzSQLVMKit Front Page', link: '/' },
						{ label: 'Getting Started', slug: 'getting-started' },
						{ label: 'Configuration', slug: 'configuration' },
						{ label: 'Configuration Reference', slug: 'configuration-reference' },
						{ label: 'Sizing And Costs', slug: 'sizing-and-costs' },
						{ label: 'Generated Naming', slug: 'naming-reference' },
						{ label: 'Plan vs WhatIf', slug: 'plan-vs-whatif' },
					],
				},
				{
					label: 'Security',
					items: [
						{ label: 'Security', slug: 'security' },
					],
				},
				{
					label: 'Licensing',
					items: [
						{ label: 'Licensing', link: '/licensing/' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'Command Reference', slug: 'command-reference' },
						{ label: 'Sample Databases', slug: 'sample-databases' },
						{ label: 'SQL Community Tools', slug: 'sql-community-tools' },
						{ label: 'Azure Bastion', slug: 'bastion' },
						{ label: 'Deployment Flow', slug: 'deployment-flow' },
						{ label: 'Resource Model', slug: 'resource-model' },
						{ label: 'Guest Setup', slug: 'guest-setup' },
						{ label: 'Architecture', slug: 'architecture' },
					],
				},
				{
					label: 'Operate And Maintain',
					items: [
						{ label: 'Local Testing', slug: 'testing' },
						{ label: 'Troubleshooting', slug: 'troubleshooting' },
					],
				},
				{
					label: 'Development',
					items: [
						{ label: 'Development', slug: 'development' },
						{ label: 'Roadmap', slug: 'roadmap' },
					],
				},
				{
					label: 'Third-party Notices',
					items: [
						{ label: 'Hall of Fame', slug: 'hall-of-fame' },
						{ label: 'Third-party Notices', link: '/third-party-notices/' },
					],
				},
			],
		}),
	],
});
