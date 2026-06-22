<template>
	<a class="front-page-link" href="/azure-sqlvm-toolkit/">Back to front page</a>
</template>

<style scoped>
.front-page-link {
	position: fixed;
	top: 1rem;
	right: 1rem;
	z-index: 100;
	border: 1px solid rgba(125, 211, 252, 0.48);
	border-radius: 999px;
	padding: 0.4rem 0.7rem;
	background: rgba(15, 23, 42, 0.78);
	color: #e5edf8;
	font-size: 0.78rem;
	font-weight: 700;
	line-height: 1;
	text-decoration: none;
	backdrop-filter: blur(10px);
}

.front-page-link:hover {
	background: rgba(14, 165, 233, 0.9);
	color: #06111f;
}

@media print {
	.front-page-link {
		display: none;
	}
}
</style>
