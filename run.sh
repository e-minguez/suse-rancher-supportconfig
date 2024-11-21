#!/bin/bash
set -euo pipefail

# TODO(eminguez): not sure about this
trap 'test -d ${FOLDER} && rm -rf -- "${FOLDER}"' ERR

export GUM_SPIN_SPINNER="dot"

die(){
	echo "${1}" 1>&2
	exit "${2}"
}

init() {
	clear
	gum style \
		--foreground 212 --border-foreground 212 --border double \
		--align center --width 50 --margin "1 2" --padding "2 4" \
		'This script will collect all the required information from you Kubernetes cluster and nodes.' 'It will ask you some questions and then run rancher2_logs_collector.sh and supportconfig'
	gum confirm || die "Aborting" 0
}

get_kubeconfig() {
	# Ask for kubeconfig
	export KUBECONFIG=$(gum input --header "Type the kubeconfig location" --placeholder="~/.kube/config")
	[[ -z "${KUBECONFIG}" ]] && export KUBECONFIG="~/.kube/config"

	if [[ ! -f "${KUBECONFIG}" ]]; then
		die "kubeconfig ${KUBECONFIG} is not a valid file." 1
	fi
}

select_nodes() {
	#ALLNODES=$(gum spin --show-output --title "Getting the list of nodes..." -- kubectl get nodes -o go-template='{{range .items}}{{.metadata.name}}({{range .status.conditions}}{{if eq .type "Ready"}}{{if eq .status "True"}}Ready{{else}}Not Ready{{end}}{{end}}{{end}}){{"\n"}}{{end}}')
	ALLNODES=$(kubectl get nodes -o go-template='{{range .items}}{{.metadata.name}}({{range .status.conditions}}{{if eq .type "Ready"}}{{if eq .status "True"}}Ready{{else}}Not Ready{{end}}{{end}}{{end}}){{"\n"}}{{end}}')
	[[ -z "${ALLNODES}" ]] && die "Not able to get the nodes" 1

	SELECTEDNODES=$(gum choose --no-limit --header "Choose the nodes" $(echo "${ALLNODES}" | tr '\n' ' '))
	if [[ -z "${SELECTEDNODES}" ]]; then
		die "Not valid selection" 1
	fi
}

collect_logs_from_node(){
	NODE="${1}"
	gum style \
		--foreground 212 --border-foreground 212 --border double \
		--align center --width 50 --margin "1 2" --padding "2 4" \
		"Collecting logs from ${NODE}"
	FOLDER=$(mktemp -d)
	if ! gum spin --title "Downloading rancher2_logs_collector.sh locally..." -- curl -Ls https://raw.githubusercontent.com/rancherlabs/support-tools/master/collection/rancher/v2.x/logs-collector/rancher2_logs_collector.sh -o ${FOLDER}/rancher2_logs_collector.sh; then
		die "Error downloading rancher2_logs_collector.sh locally" 1
	fi
	chmod a+x ${FOLDER}/rancher2_logs_collector.sh || die "Error setting ${FOLDER}/rancher2_logs_collector.sh the executable bit" 1

	SCPUSER=$(gum input --header "Type the ssh user to connect to the ${NODE} host" --placeholder "root")
	[[ -z "${SCPUSER}" ]] && SCPUSER="root"
	if [[ "${SCPUSER}" != "root" ]]; then
		echo "The rancher2_logs_collector.sh script requires root permissions, so it will use sudo"
		SUDO=true
	else
		SUDO=false
	fi

	SCPHOST=$(gum input --header "Type the hostname or IP of the ${NODE} host" --placeholder "${NODE}")
	[[ -z "${SCPHOST}" ]] && SCPHOST="${NODE}"

	DESTINATION=$(gum input --header "Type the destionation folder on the ${NODE} host for the rancher2_logs_collector.sh script" --placeholder "/tmp/")
	[[ -z "${DESTINATION}" ]] && DESTINATION="/tmp/"

	if [ ${SUDO} == "true" ]; then
		# Small hack to add a new line after the output...
		COMMAND="echo '' && sudo ${DESTINATION}/rancher2_logs_collector.sh -d ${DESTINATION}/output"
	else
		# Small hack to add a new line after the output...
		COMMAND="echo '' && ${DESTINATION}/rancher2_logs_collector.sh -d ${DESTINATION}/output"
	fi

	gum spin --title "Creating ${DESTINATION} on ${NODE}" -- ssh "${SCPUSER}"@"${SCPHOST}" "mkdir -p ${DESTINATION}/output" || die "Error creating ${DESTINATION} on ${NODE}" 1
	gum spin --title "Uploading rancher2_logs_collector.sh to ${NODE}:${DESTINATION}..." -- scp ${FOLDER}/rancher2_logs_collector.sh "${SCPUSER}"@"${SCPHOST}":"${DESTINATION}" || die "Error uploading rancher2_logs_collector.sh to ${NODE}:${DESTINATION}" 1
	gum spin --show-output --title "Running rancher2_logs_collector.sh on ${NODE}" --  ssh "${SCPUSER}"@"${SCPHOST}" "${COMMAND}" || die "Error running rancher2_logs_collector.sh on ${NODE}" 1
	gum spin --title "Collecting the log file on ${NODE}" -- scp "${SCPUSER}"@"${SCPHOST}":"${DESTINATION}/output/*.tar.gz" "${FOLDER}"/ || die "Error collecting the log file on ${NODE}" 1
	RESULTS=$(find ${FOLDER} -type f -iname "*.tar.gz")
	echo "File available at ${RESULTS}"

	OSID=$(ssh "${SCPUSER}"@"${SCPHOST}" -- grep '^ID=' /etc/os-release)
	if [[ "${OSID}" != 'ID="sl-micro"' ]]; then
		echo "Done"
	else
		if gum confirm "The OS has been detected as SL Micro, do you want to run supportconfig there?" ; then
			gum spin --show-output --title "Running supportconfig on ${NODE}" -- ssh "${SCPUSER}"@"${SCPHOST}" supportconfig -R "${DESTINATION}/output/" || die "Error running supportconfig on ${NODE}" 1
			gum spin --title "Collecting the supportconfig files on ${NODE}" -- scp "${SCPUSER}"@"${SCPHOST}":"${DESTINATION}/output/*.txz*" "${FOLDER}"/ || die "Error collecting the log file on ${NODE}" 1
			RESULTS=$(find ${FOLDER} -type f -iname "*.txz")
			echo "File available at ${RESULTS}"
		fi
	fi
}

init
get_kubeconfig
select_nodes

gum confirm "Are you sure you want to run rancher2_logs_collector.sh against $(echo ${SELECTEDNODES} | tr '\n' ' ')?" || die "Aborting" 0
for NODE in ${SELECTEDNODES}; do
	NODE=$(echo "${NODE}" | cut -d"(" -f1)
	collect_logs_from_node ${NODE}
done

exit 0