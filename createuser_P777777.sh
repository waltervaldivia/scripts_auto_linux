#!/bin/bash
# ==============================================================================
# Guía de Configuración: Usuario PAM + Acceso SSH
# Sistema : Oracle Linux Server
# Usuario : P777777777
# Modo    : SOLO AGREGAR — no elimina ni sobreescribe contenido existente
# Uso     : sudo bash setup_pam_user_P777777777.sh
# ==============================================================================

set -euo pipefail

# ── COLORES ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── VARIABLES ──────────────────────────────────────────────────────────────────
USERNAME="P777777777"
PASSWORD="Temp@123456"          # Contraseña permanente — no expira
SSHD_CONFIG="/etc/ssh/sshd_config"
SUDOERS_FILE="/etc/sudoers"
PAM_ENV_FILE="/etc/security/pam_env.conf"
BASH_PROFILE="/home/${USERNAME}/.bash_profile"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/var/log/setup_pam_${USERNAME}_${TIMESTAMP}.log"

# ── FUNCIONES DE LOG ──────────────────────────────────────────────────────────
log()    { echo -e "${GREEN}[OK]${NC}  $1" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
info()   { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
header() { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}" | tee -a "$LOG_FILE"; }

# ── VERIFICAR ROOT ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root o con sudo."
    exit 1
fi

echo "============================================================" | tee "$LOG_FILE"
echo "  Setup PAM User: ${USERNAME}"                                | tee -a "$LOG_FILE"
echo "  Inicio: $(date)"                                            | tee -a "$LOG_FILE"
echo "  Log: ${LOG_FILE}"                                           | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# ==============================================================================
# SECCIÓN 2: CREACIÓN DE USUARIO
# ==============================================================================
header "2. Creación de usuario"

if id "${USERNAME}" &>/dev/null; then
    warn "El usuario ${USERNAME} ya existe. Se omite creación."
else
    useradd -m -s /bin/bash "${USERNAME}"
    log "Usuario ${USERNAME} creado con home /home/${USERNAME} y shell bash."
fi

# Establecer contraseña permanente (no expira, no fuerza cambio en login)
echo "${USERNAME}:${PASSWORD}" | chpasswd
log "Contraseña permanente asignada: ${PASSWORD}"

# Desactivar expiración completa:
#   -M -1  : sin máximo de días (contraseña NUNCA expira)
#   -m 0   : sin mínimo de días entre cambios
#   -W -1  : sin días de aviso previo a expiración
#   -I -1  : sin inactividad que bloquee la cuenta
#   -E -1  : sin fecha de expiración de la cuenta
chage -M -1 -m 0 -W -1 -I -1 -E -1 "${USERNAME}"
log "Contraseña configurada como PERMANENTE con chage -M -1 (nunca expira)."

# Verificar estado de expiración
chage -l "${USERNAME}" | tee -a "$LOG_FILE"

# Asegurar que la cuenta no esté bloqueada
passwd -u "${USERNAME}" &>/dev/null || true
log "Cuenta ${USERNAME} desbloqueada y activa."

# ==============================================================================
# SECCIÓN 3: PERMISOS ADMINISTRATIVOS (grupo wheel)
# ==============================================================================
header "3. Asignación de permisos administrativos"

if groups "${USERNAME}" | grep -qw "wheel"; then
    warn "El usuario ${USERNAME} ya pertenece al grupo wheel. Se omite."
else
    usermod -aG wheel "${USERNAME}"
    log "Usuario ${USERNAME} agregado al grupo wheel."
fi

# ==============================================================================
# SECCIÓN 4: CONFIGURACIÓN SSH
# ==============================================================================
header "4. Configuración de acceso SSH"

# ── Backup del sshd_config ────────────────────────────────────────────────────
SSHD_BACKUP="${SSHD_CONFIG}.bak_${TIMESTAMP}"
cp "${SSHD_CONFIG}" "${SSHD_BACKUP}"
log "Backup de sshd_config guardado en: ${SSHD_BACKUP}"

# ── 4.1: Asegurar UsePAM yes (global, fuera de bloque Match) ─────────────────
info "4.1 Verificando directiva global UsePAM..."

if grep -qE "^UsePAM\s+yes" "${SSHD_CONFIG}"; then
    warn "UsePAM yes ya existe en sshd_config. Se omite."
else
    if grep -qE "^UsePAM\s+" "${SSHD_CONFIG}"; then
        # Existe UsePAM pero con valor diferente — agregar línea correcta debajo
        warn "Existe directiva UsePAM con valor distinto. Se agrega UsePAM yes al final del bloque global."
        # Insertar antes del primer bloque Match para que sea global
        if grep -q "^Match " "${SSHD_CONFIG}"; then
            sed -i "/^Match /i UsePAM yes" "${SSHD_CONFIG}"
        else
            echo "UsePAM yes" >> "${SSHD_CONFIG}"
        fi
    else
        # No existe UsePAM — agregar globalmente antes del primer Match o al final
        if grep -q "^Match " "${SSHD_CONFIG}"; then
            sed -i "/^Match /i UsePAM yes" "${SSHD_CONFIG}"
        else
            echo "UsePAM yes" >> "${SSHD_CONFIG}"
        fi
    fi
    log "UsePAM yes agregado al sshd_config."
fi


# ── 4.15: Agregar usuario a AllowUsers ───────────────────────────────────────
info "4.15 Verificando directiva AllowUsers en sshd_config..."

# Obtener la línea AllowUsers principal (la que tiene opc usr_pluz_so)
ALLOW_LINE=$(grep -E "^AllowUsers" "${SSHD_CONFIG}" | head -1)

if [[ -z "${ALLOW_LINE}" ]]; then
    # No existe ninguna directiva AllowUsers — agregar nueva
    warn "No se encontró ninguna directiva AllowUsers en sshd_config."
    warn "Se agrega nueva línea: AllowUsers ${USERNAME}"
    if grep -q "^Match " "${SSHD_CONFIG}"; then
        sed -i "/^Match /i AllowUsers ${USERNAME}" "${SSHD_CONFIG}"
    else
        echo "AllowUsers ${USERNAME}" >> "${SSHD_CONFIG}"
    fi
    log "Línea 'AllowUsers ${USERNAME}' agregada al sshd_config."
else
    # Mostrar usuarios actualmente permitidos
    info "Directiva AllowUsers encontrada:"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  ANTES:  ${ALLOW_LINE}"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    # Extraer solo los usuarios (quitar el prefijo "AllowUsers ")
    CURRENT_USERS=$(echo "${ALLOW_LINE}" | sed 's/^AllowUsers //')
    info "Usuarios actualmente en AllowUsers: ${CURRENT_USERS}"

    # Verificar si P777777777 ya está incluido
    if echo "${ALLOW_LINE}" | grep -qw "${USERNAME}"; then
        warn "El usuario ${USERNAME} ya existe en AllowUsers. No se realizan cambios."
    else
        info "El usuario ${USERNAME} NO está en AllowUsers. Procediendo a agregarlo..."

        # Agregar USERNAME al final de la línea existente
        sed -i "s/^AllowUsers ${CURRENT_USERS}/AllowUsers ${CURRENT_USERS} ${USERNAME}/" "${SSHD_CONFIG}"

        # Mostrar resultado final
        NEW_LINE=$(grep -E "^AllowUsers" "${SSHD_CONFIG}" | head -1)
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │  DESPUÉS: ${NEW_LINE}"
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        log "Usuario ${USERNAME} agregado. Todos los usuarios AllowUsers:"
        grep -E "^AllowUsers" "${SSHD_CONFIG}" | while read -r line; do
            echo "    → ${line}" | tee -a "$LOG_FILE"
        done
    fi
fi

# ── 4.2: Bloque Match User específico ────────────────────────────────────────
info "4.2 Verificando bloque Match User ${USERNAME}..."

MATCH_BLOCK="Match User ${USERNAME}
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes"

if grep -q "Match User ${USERNAME}" "${SSHD_CONFIG}"; then
    warn "Bloque 'Match User ${USERNAME}' ya existe en sshd_config. Se omite."
else
    {
        echo ""
        echo "# Bloque agregado por script setup_pam_user — ${TIMESTAMP}"
        echo "Match User ${USERNAME}"
        echo "    PasswordAuthentication yes"
        echo "    KbdInteractiveAuthentication yes"
    } >> "${SSHD_CONFIG}"
    log "Bloque Match User ${USERNAME} agregado al sshd_config."
fi

# ── 4.3: Validar configuración SSH ────────────────────────────────────────────
info "4.3 Validando configuración SSH..."
if sshd -t 2>>"$LOG_FILE"; then
    log "Configuración SSH válida (sshd -t sin errores)."
else
    error "Error en la configuración SSH. Revisa ${LOG_FILE}."
    error "Restaurando backup: ${SSHD_BACKUP}"
    cp "${SSHD_BACKUP}" "${SSHD_CONFIG}"
    exit 1
fi

# ── 4.4: Reiniciar servicio SSHD ──────────────────────────────────────────────
info "4.4 Reiniciando servicio sshd..."
systemctl restart sshd
log "Servicio sshd reiniciado correctamente."

# ==============================================================================
# SECCIÓN 5: CONFIGURACIÓN DE SUDOERS
# ==============================================================================
header "5. Configuración de sudoers"

SUDOERS_ENTRY_1="Defaults:${USERNAME} !requiretty"
SUDOERS_ENTRY_2="${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/passwd"

# Verificar y agregar cada línea solo si no existe
SUDOERS_MODIFIED=false

if grep -qF "${SUDOERS_ENTRY_1}" "${SUDOERS_FILE}"; then
    warn "Entrada '${SUDOERS_ENTRY_1}' ya existe en sudoers. Se omite."
else
    # Insertar antes de la línea #includedir usando un archivo temporal validado
    SUDOERS_TMP=$(mktemp)
    cp "${SUDOERS_FILE}" "${SUDOERS_TMP}"

    if grep -q "^#includedir" "${SUDOERS_TMP}"; then
        sed -i "/^#includedir/i # Agregado por script setup_pam_user — ${TIMESTAMP}\n${SUDOERS_ENTRY_1}" "${SUDOERS_TMP}"
    else
        echo "# Agregado por script setup_pam_user — ${TIMESTAMP}" >> "${SUDOERS_TMP}"
        echo "${SUDOERS_ENTRY_1}" >> "${SUDOERS_TMP}"
    fi
    SUDOERS_MODIFIED=true

    # Validar antes de aplicar
    if visudo -cf "${SUDOERS_TMP}" &>/dev/null; then
        cp "${SUDOERS_TMP}" "${SUDOERS_FILE}"
        log "Entrada '${SUDOERS_ENTRY_1}' agregada a sudoers."
    else
        error "Sintaxis inválida al agregar sudoers entry 1. Se revierte."
        rm -f "${SUDOERS_TMP}"
        exit 1
    fi
    rm -f "${SUDOERS_TMP}"
fi

if grep -qF "${SUDOERS_ENTRY_2}" "${SUDOERS_FILE}"; then
    warn "Entrada '${SUDOERS_ENTRY_2}' ya existe en sudoers. Se omite."
else
    SUDOERS_TMP=$(mktemp)
    cp "${SUDOERS_FILE}" "${SUDOERS_TMP}"

    if grep -q "^#includedir" "${SUDOERS_TMP}"; then
        sed -i "/^#includedir/i ${SUDOERS_ENTRY_2}" "${SUDOERS_TMP}"
    else
        echo "${SUDOERS_ENTRY_2}" >> "${SUDOERS_TMP}"
    fi
    SUDOERS_MODIFIED=true

    if visudo -cf "${SUDOERS_TMP}" &>/dev/null; then
        cp "${SUDOERS_TMP}" "${SUDOERS_FILE}"
        log "Entrada '${SUDOERS_ENTRY_2}' agregada a sudoers."
    else
        error "Sintaxis inválida al agregar sudoers entry 2. Se revierte."
        rm -f "${SUDOERS_TMP}"
        exit 1
    fi
    rm -f "${SUDOERS_TMP}"
fi

if [ "$SUDOERS_MODIFIED" = false ]; then
    warn "No se realizaron cambios en sudoers (entradas ya existían)."
fi

# ==============================================================================
# SECCIÓN 6: CONFIGURACIÓN DE IDIOMA
# ==============================================================================
header "6. Configuración de idioma"

# ── 6.1: pam_env.conf — agregar comentadas al final si no existen ─────────────
info "6.1 Verificando /etc/security/pam_env.conf..."

PAM_ENTRY_1="#LANG DEFAULT=en_US.UTF-8"
PAM_ENTRY_2="#LC_ALL DEFAULT=en_US.UTF-8"

{
    if ! grep -qF "${PAM_ENTRY_1}" "${PAM_ENV_FILE}" 2>/dev/null; then
        echo "${PAM_ENTRY_1}" >> "${PAM_ENV_FILE}"
        log "Agregado '${PAM_ENTRY_1}' a pam_env.conf."
    else
        warn "'${PAM_ENTRY_1}' ya existe en pam_env.conf. Se omite."
    fi

    if ! grep -qF "${PAM_ENTRY_2}" "${PAM_ENV_FILE}" 2>/dev/null; then
        echo "${PAM_ENTRY_2}" >> "${PAM_ENV_FILE}"
        log "Agregado '${PAM_ENTRY_2}' a pam_env.conf."
    else
        warn "'${PAM_ENTRY_2}' ya existe en pam_env.conf. Se omite."
    fi
}

# ── 6.2: ~/.bash_profile del usuario ─────────────────────────────────────────
info "6.2 Verificando ${BASH_PROFILE}..."

# Crear el archivo si no existe
if [ ! -f "${BASH_PROFILE}" ]; then
    touch "${BASH_PROFILE}"
    chown "${USERNAME}:${USERNAME}" "${BASH_PROFILE}"
    log "Archivo ${BASH_PROFILE} creado."
fi

# Backup del bash_profile
PROFILE_BACKUP="${BASH_PROFILE}.bak_${TIMESTAMP}"
cp "${BASH_PROFILE}" "${PROFILE_BACKUP}"
log "Backup de .bash_profile guardado en: ${PROFILE_BACKUP}"

# Agregar export LANG solo si no existe ya (activa, no comentada)
if grep -qE "^export LANG=en_US\.UTF-8" "${BASH_PROFILE}"; then
    warn "'export LANG=en_US.UTF-8' ya existe activo en .bash_profile. Se omite."
else
    echo "export LANG=en_US.UTF-8" >> "${BASH_PROFILE}"
    log "Agregado 'export LANG=en_US.UTF-8' a .bash_profile."
fi

# LC_ALL se agrega comentada (según la guía)
if grep -qE "^#export LC_ALL=en_US\.UTF-8" "${BASH_PROFILE}"; then
    warn "'#export LC_ALL=en_US.UTF-8' ya existe comentado en .bash_profile. Se omite."
else
    echo "#export LC_ALL=en_US.UTF-8" >> "${BASH_PROFILE}"
    log "Agregado '#export LC_ALL=en_US.UTF-8' (comentado) a .bash_profile."
fi

# Asegurar permisos correctos
chown "${USERNAME}:${USERNAME}" "${BASH_PROFILE}"
chmod 644 "${BASH_PROFILE}"
log "Permisos de ${BASH_PROFILE} verificados."

# ==============================================================================
# VALIDACIÓN FINAL
# ==============================================================================
header "Validación final"

info "Verificando usuario..."
id "${USERNAME}" | tee -a "$LOG_FILE" && log "Usuario ${USERNAME} existe."

info "Verificando grupo wheel..."
groups "${USERNAME}" | grep -qw wheel && log "Pertenece al grupo wheel." || warn "NO pertenece a wheel."

info "Verificando sshd activo..."
systemctl is-active sshd &>/dev/null && log "sshd está activo." || warn "sshd no está activo."

info "Verificando AllowUsers..."
grep "AllowUsers" "${SSHD_CONFIG}" | tee -a "$LOG_FILE"

info "Verificando bloque Match en sshd_config..."
grep -A3 "Match User ${USERNAME}" "${SSHD_CONFIG}" | tee -a "$LOG_FILE"

info "Verificando sudoers..."
grep "${USERNAME}" "${SUDOERS_FILE}" | tee -a "$LOG_FILE"

info "Verificando expiración de contraseña..."
chage -l "${USERNAME}" | grep -E "Password expires|Account expires" | tee -a "$LOG_FILE"

info "Verificando .bash_profile..."
grep -v "^$" "${BASH_PROFILE}" | tail -5 | tee -a "$LOG_FILE"

# ==============================================================================
# RESUMEN
# ==============================================================================
echo "" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
echo -e "  ${GREEN}${BOLD}CONFIGURACIÓN COMPLETADA${NC}"                | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
echo "  Usuario      : ${USERNAME}"                                  | tee -a "$LOG_FILE"
echo "  Contraseña   : ${PASSWORD} (PERMANENTE — no expira)"    | tee -a "$LOG_FILE"
echo "  Grupo        : wheel (sudo habilitado)"                      | tee -a "$LOG_FILE"
echo "  SSH          : PasswordAuthentication + KbdInteractive ON"   | tee -a "$LOG_FILE"
echo "  Sudo         : NOPASSWD para /usr/bin/passwd"                | tee -a "$LOG_FILE"
echo "  LANG         : en_US.UTF-8 en .bash_profile"                 | tee -a "$LOG_FILE"
echo "  Log completo : ${LOG_FILE}"                                   | tee -a "$LOG_FILE"
echo "  Backups:"                                                     | tee -a "$LOG_FILE"
echo "    sshd_config  : ${SSHD_BACKUP}"                             | tee -a "$LOG_FILE"
echo "    .bash_profile: ${PROFILE_BACKUP}"                          | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
echo ""
echo -e "${YELLOW}SIGUIENTE PASO:${NC} Conectar vía SSH para verificar acceso:"
echo "  ssh ${USERNAME}@<IP_DEL_SERVIDOR>"
echo "  Password: ${PASSWORD}"
echo ""