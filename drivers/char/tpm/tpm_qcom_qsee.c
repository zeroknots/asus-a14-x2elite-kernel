// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm QSEE TPM transport driver.
 */

#include <linux/auxiliary_bus.h>
#include <linux/byteorder/generic.h>
#include <linux/device.h>
#include <linux/efi.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sizes.h>
#include <linux/slab.h>
#include <linux/types.h>

#include <linux/firmware/qcom/qcom_qseecom.h>
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/firmware/qcom/qcom_tzmem.h>

#include "tpm.h"

#define QCOM_TPM_QSEE_CONTROL_AREA_SIZE	(SZ_4K * 3)
#define QCOM_TPM_QSEE_COMMAND_SIZE		TPM_BUFSIZE
#define QCOM_TPM_QSEE_RESPONSE_SIZE		TPM_BUFSIZE
#define QCOM_TPM_QSEE_MAX_TA_DATA_SIZE	SZ_1K

#define QCOM_TPM_TYPE_DTPM		0x6454504d
#define QCOM_TPM_TYPE_FTPM		0x6654504d
#define QCOM_TPM_TYPE_STPM		0x7354504d

#define QCOM_TPM_QSEE_CMD_GET_VERSION	0x1000
#define QCOM_TPM_QSEE_CMD_QUERY_INFO_2	(0x4000 | 18)
#define QCOM_TPM_QSEE_CMD_SEND_COMMAND	(0x4000 | 8)

/* CRB control area: status error bit, and the Windows driver's transfer timeout. */
#define QCOM_TPM_QSEE_CA_STATUS_ERROR	BIT(0)
#define QCOM_TPM_QSEE_TIMEOUT_US	(5 * USEC_PER_SEC)

struct qcom_tpm_qsee_control_area {
	__le32 request;
	__le32 status;
	__le32 cancel;
	__le32 start;
	__le64 interrupt_control;
	__le32 command_size;
	__le64 command;
	__le32 response_size;
	__le64 response;
} __packed;

#define QCOM_TPM_QSEE_CONTROL_AREA_CMD_OFF	\
	(sizeof(struct qcom_tpm_qsee_control_area))
#define QCOM_TPM_QSEE_CA_STATUS		\
	offsetof(struct qcom_tpm_qsee_control_area, status)
#define QCOM_TPM_QSEE_CA_START		\
	offsetof(struct qcom_tpm_qsee_control_area, start)
#define QCOM_TPM_QSEE_CA_CANCEL		\
	offsetof(struct qcom_tpm_qsee_control_area, cancel)
#define QCOM_TPM_QSEE_CA_COMMAND_SIZE	\
	offsetof(struct qcom_tpm_qsee_control_area, command_size)
#define QCOM_TPM_QSEE_CA_COMMAND	\
	offsetof(struct qcom_tpm_qsee_control_area, command)
#define QCOM_TPM_QSEE_CA_RESPONSE_SIZE	\
	offsetof(struct qcom_tpm_qsee_control_area, response_size)
#define QCOM_TPM_QSEE_CA_RESPONSE	\
	offsetof(struct qcom_tpm_qsee_control_area, response)

struct qcom_tpm_qsee_version_rsp {
	__le32 status;
	__le64 version;
} __packed;

struct qcom_tpm_qsee_query_req {
	__le32 command_id;
} __packed;

struct qcom_tpm_qsee_query_rsp {
	__le32 nv_store_size;
	__le64 control_area;
} __packed;

struct qcom_tpm_qsee_send_req {
	__le32 command_id;
	__le32 input_size;
	u8 input[QCOM_TPM_QSEE_MAX_TA_DATA_SIZE];
} __packed;

struct qcom_tpm_qsee_send_rsp {
	__le32 output_size;
	u8 output[QCOM_TPM_QSEE_MAX_TA_DATA_SIZE];
} __packed;

/**
 * struct qcom_tpm_qsee - Qualcomm QSEE TPM driver state.
 * @client: QSEECOM client for qcom.tz.tpm.
 * @mempool: TZ memory pool for QSEECOM request/response buffers.
 * @chip: TPM chip registered with the TPM core.
 * @control_area: Mapped TPM control area.
 * @control_area_phys: Physical address of the TPM control area.
 * @control_area_shm_bridge: SHM bridge handle for the TPM control area.
 * @lock: Serializes access to the TPM control area and TA command path.
 */
struct qcom_tpm_qsee {
	struct qseecom_client *client;
	struct qcom_tzmem_pool *mempool;
	struct tpm_chip *chip;
	void __iomem *control_area;
	phys_addr_t control_area_phys;
	u64 control_area_shm_bridge;
	/* Serializes access to the TPM control area and TA command path. */
	struct mutex lock;
};

static const char *qcom_tpm_type_name(u64 type)
{
	switch (type) {
	case QCOM_TPM_TYPE_DTPM:
		return "dTPM";
	case QCOM_TPM_TYPE_FTPM:
		return "fTPM";
	case QCOM_TPM_TYPE_STPM:
		return "sTPM";
	default:
		return "unknown";
	}
}

static int qcom_tpm_qsee_app_send(struct qcom_tpm_qsee *qtpm, const void *req,
				  size_t req_size, void *rsp, size_t rsp_size)
{
	size_t rsp_off;
	size_t cmd_buf_size;
	void *cmd_buf;
	int ret;

	rsp_off = ALIGN(req_size, 8);
	cmd_buf_size = rsp_off + rsp_size;

	cmd_buf = qcom_tzmem_alloc(qtpm->mempool, cmd_buf_size, GFP_KERNEL);
	if (!cmd_buf)
		return -ENOMEM;

	memset(cmd_buf, 0, cmd_buf_size);
	memcpy(cmd_buf, req, req_size);

	ret = qcom_qseecom_app_send(qtpm->client, cmd_buf, req_size,
				    cmd_buf + rsp_off, rsp_size);
	if (!ret && rsp_size)
		memcpy(rsp, cmd_buf + rsp_off, rsp_size);

	qcom_tzmem_free(cmd_buf);
	return ret;
}

static int qcom_tpm_qsee_get_version(struct qcom_tpm_qsee *qtpm, u64 *version)
{
	struct qcom_tpm_qsee_query_req req = {
		.command_id = cpu_to_le32(QCOM_TPM_QSEE_CMD_GET_VERSION),
	};
	struct qcom_tpm_qsee_version_rsp rsp = {};
	int ret;

	ret = qcom_tpm_qsee_app_send(qtpm, &req, sizeof(req), &rsp, sizeof(rsp));
	if (ret)
		return ret;

	if (le32_to_cpu(rsp.status))
		return -ENODEV;

	*version = le64_to_cpu(rsp.version);
	return 0;
}

/*
 * The control area must be firmware-reserved memory: wholly inside one UEFI
 * memory descriptor of a reserved type (on the UX3407NA: EfiReservedMemoryType,
 * write-combining), never System RAM or device registers.
 */
static bool qcom_tpm_qsee_control_area_valid(u64 base)
{
	u64 end = base + QCOM_TPM_QSEE_CONTROL_AREA_SIZE;
	efi_memory_desc_t md;

	if (!base || !PAGE_ALIGNED(base) || end < base)
		return false;

	if (region_intersects(base, QCOM_TPM_QSEE_CONTROL_AREA_SIZE,
			      IORESOURCE_SYSTEM_RAM, IORES_DESC_NONE) !=
	    REGION_DISJOINT)
		return false;

	if (efi_mem_desc_lookup(base, &md))
		return false;

	switch (md.type) {
	case EFI_RESERVED_TYPE:
	case EFI_RUNTIME_SERVICES_DATA:
	case EFI_ACPI_MEMORY_NVS:
		break;
	default:
		return false;
	}

	return end <= md.phys_addr + (md.num_pages << EFI_PAGE_SHIFT);
}

static int qcom_tpm_qsee_query_info(struct qcom_tpm_qsee *qtpm)
{
	struct qcom_tpm_qsee_query_req req = {
		.command_id = cpu_to_le32(QCOM_TPM_QSEE_CMD_QUERY_INFO_2),
	};
	struct qcom_tpm_qsee_query_rsp rsp = {};
	u64 control_area;
	int ret;

	ret = qcom_tpm_qsee_app_send(qtpm, &req, sizeof(req), &rsp, sizeof(rsp));
	if (ret)
		return ret;

	control_area = le64_to_cpu(rsp.control_area);
	/*
	 * The driver writes TPM commands into this range and shares it with
	 * TrustZone, so a different reply layout must not point it elsewhere.
	 */
	if (!qcom_tpm_qsee_control_area_valid(control_area))
		return -EINVAL;

	qtpm->control_area_phys = control_area;

	return 0;
}

static int qcom_tpm_qsee_send_ta_command(struct qcom_tpm_qsee *qtpm,
					 u32 command_id, u32 input_size,
					 const void *input)
{
	struct qcom_tpm_qsee_send_req *req;
	size_t req_size = sizeof(struct qcom_tpm_qsee_send_req);
	size_t rsp_size = sizeof(struct qcom_tpm_qsee_send_rsp);
	size_t rsp_off = ALIGN(req_size, 8);
	size_t cmd_buf_size = rsp_off + rsp_size;
	void *cmd_buf;
	int ret;

	if (input_size > QCOM_TPM_QSEE_MAX_TA_DATA_SIZE)
		return -EINVAL;

	cmd_buf = qcom_tzmem_alloc(qtpm->mempool, cmd_buf_size, GFP_KERNEL);
	if (!cmd_buf)
		return -ENOMEM;

	memset(cmd_buf, 0, cmd_buf_size);

	req = cmd_buf;
	req->command_id = cpu_to_le32(command_id);
	req->input_size = cpu_to_le32(input_size);
	if (input_size && input)
		memcpy(req->input, input, input_size);

	ret = qcom_qseecom_app_send(qtpm->client, cmd_buf, req_size,
				    cmd_buf + rsp_off, rsp_size);
	/*
	 * The reply layout is not documented; GET_VERSION starts with a status
	 * word, so report a nonzero first word without failing on it yet.
	 */
	if (!ret && le32_to_cpup((__le32 *)(cmd_buf + rsp_off)))
		dev_warn_once(&qtpm->client->aux_dev.dev,
			      "TA command %#x reply word %#x\n", command_id,
			      le32_to_cpup((__le32 *)(cmd_buf + rsp_off)));

	qcom_tzmem_free(cmd_buf);
	return ret;
}

static void qcom_tpm_qsee_delete_control_area_bridge(void *data)
{
	struct qcom_tpm_qsee *qtpm = data;

	if (qtpm->control_area_shm_bridge)
		qcom_tzmem_shm_bridge_delete(qtpm->control_area_shm_bridge);
}

static int qcom_tpm_qsee_create_control_area_bridge(struct qcom_tpm_qsee *qtpm)
{
	struct device *dev = &qtpm->client->aux_dev.dev;
	int ret;

	ret = qcom_tzmem_shm_bridge_create(qtpm->control_area_phys,
					   QCOM_TPM_QSEE_CONTROL_AREA_SIZE,
					   &qtpm->control_area_shm_bridge);
	/* A nonzero TrustZone result can come back as a positive value. */
	if (ret > 0)
		return -EIO;
	if (ret)
		return ret;

	return devm_add_action_or_reset(dev,
					qcom_tpm_qsee_delete_control_area_bridge,
					qtpm);
}

static int qcom_tpm_qsee_send(struct tpm_chip *chip, u8 *buf, size_t bufsiz,
			      size_t cmd_len)
{
	struct qcom_tpm_qsee *qtpm = dev_get_drvdata(&chip->dev);
	void __iomem *command;
	void __iomem *response;
	phys_addr_t command_phys;
	phys_addr_t response_phys;
	__le64 command_le;
	__le64 response_le;
	struct tpm_header header;
	u32 response_len;
	u32 start;
	int ret;

	if (cmd_len > QCOM_TPM_QSEE_COMMAND_SIZE)
		return -E2BIG;

	if (cmd_len < TPM_HEADER_SIZE)
		return -EINVAL;

	if (QCOM_TPM_QSEE_CONTROL_AREA_CMD_OFF + QCOM_TPM_QSEE_COMMAND_SIZE +
	    QCOM_TPM_QSEE_RESPONSE_SIZE >
	    QCOM_TPM_QSEE_CONTROL_AREA_SIZE)
		return -E2BIG;

	mutex_lock(&qtpm->lock);

	command = qtpm->control_area + QCOM_TPM_QSEE_CONTROL_AREA_CMD_OFF;
	response = command + QCOM_TPM_QSEE_COMMAND_SIZE;
	command_phys = qtpm->control_area_phys +
		       QCOM_TPM_QSEE_CONTROL_AREA_CMD_OFF;
	response_phys = command_phys + QCOM_TPM_QSEE_COMMAND_SIZE;
	command_le = cpu_to_le64(command_phys);
	response_le = cpu_to_le64(response_phys);

	/*
	 * CRB defines status as read-only for the host, but both known working
	 * drivers for this app (Radxa SC8280XP, Dell XPS 13 9345) clear it
	 * before each command; keep that until the TA's behaviour is known.
	 */
	writel(0, qtpm->control_area + QCOM_TPM_QSEE_CA_CANCEL);
	writel(0, qtpm->control_area + QCOM_TPM_QSEE_CA_STATUS);
	memcpy_toio(command, buf, cmd_len);
	memset_io(response, 0, QCOM_TPM_QSEE_RESPONSE_SIZE);

	writel(QCOM_TPM_QSEE_COMMAND_SIZE,
	       qtpm->control_area + QCOM_TPM_QSEE_CA_COMMAND_SIZE);
	memcpy_toio(qtpm->control_area + QCOM_TPM_QSEE_CA_COMMAND, &command_le,
		    sizeof(command_le));
	writel(QCOM_TPM_QSEE_RESPONSE_SIZE,
	       qtpm->control_area + QCOM_TPM_QSEE_CA_RESPONSE_SIZE);
	memcpy_toio(qtpm->control_area + QCOM_TPM_QSEE_CA_RESPONSE, &response_le,
		    sizeof(response_le));
	writel(1, qtpm->control_area + QCOM_TPM_QSEE_CA_START);

	/* Ensure the TA observes the command and control area writes. */
	wmb();

	ret = qcom_tpm_qsee_send_ta_command(qtpm,
					    QCOM_TPM_QSEE_CMD_SEND_COMMAND,
					    0, NULL);
	if (ret)
		goto out_unlock;

	/* The TA clears start when it has finished with the command. */
	ret = readl_poll_timeout(qtpm->control_area + QCOM_TPM_QSEE_CA_START,
				 start, !start, 20, QCOM_TPM_QSEE_TIMEOUT_US);
	if (ret) {
		dev_err(&chip->dev, "TPM command did not complete\n");
		writel(1, qtpm->control_area + QCOM_TPM_QSEE_CA_CANCEL);
		goto out_unlock;
	}

	if (readl(qtpm->control_area + QCOM_TPM_QSEE_CA_STATUS) &
	    QCOM_TPM_QSEE_CA_STATUS_ERROR) {
		dev_err(&chip->dev, "TPM reported an error\n");
		ret = -EIO;
		goto out_unlock;
	}

	/* Ensure the CPU observes the TA response writes before reading them. */
	rmb();

	memcpy_fromio(&header, response, sizeof(header));
	response_len = be32_to_cpu(header.length);

	if (response_len < TPM_HEADER_SIZE) {
		ret = -EIO;
		goto out_unlock;
	}

	if (response_len > QCOM_TPM_QSEE_RESPONSE_SIZE || response_len > bufsiz) {
		ret = -EIO;
		goto out_unlock;
	}

	memcpy_fromio(buf, response, response_len);
	ret = response_len;

out_unlock:
	mutex_unlock(&qtpm->lock);
	return ret;
}

static const struct tpm_class_ops qcom_tpm_qsee_ops = {
	.flags = TPM_OPS_AUTO_STARTUP,
	.send = qcom_tpm_qsee_send,
};

static int qcom_tpm_qsee_probe(struct auxiliary_device *aux_dev,
			       const struct auxiliary_device_id *aux_dev_id)
{
	struct device *dev = &aux_dev->dev;
	struct qcom_tzmem_pool_config pool_config = {};
	struct qcom_tpm_qsee *qtpm;
	struct tpm_chip *chip;
	u64 tpm_type;
	u64 version;
	int ret;

	qtpm = devm_kzalloc(dev, sizeof(*qtpm), GFP_KERNEL);
	if (!qtpm)
		return -ENOMEM;

	qtpm->client = container_of(aux_dev, struct qseecom_client, aux_dev);
	mutex_init(&qtpm->lock);

	pool_config.initial_size = SZ_4K;
	pool_config.policy = QCOM_TZMEM_POLICY_MULTIPLIER;
	pool_config.increment = 2;
	pool_config.max_size = SZ_64K;

	qtpm->mempool = devm_qcom_tzmem_pool_new(dev, &pool_config);
	if (IS_ERR(qtpm->mempool))
		return PTR_ERR(qtpm->mempool);

	ret = qcom_scm_query_tpm_type(&tpm_type);
	if (ret == -EOPNOTSUPP) {
		dev_warn(dev, "TPM type query not available, relying on the app handshake\n");
		tpm_type = 0;
	} else if (ret) {
		return dev_err_probe(dev, ret, "failed to query TPM type\n");
	} else if (tpm_type != QCOM_TPM_TYPE_FTPM && tpm_type != QCOM_TPM_TYPE_DTPM) {
		dev_err(dev, "unsupported TPM type %#llx (%s)\n",
			tpm_type, qcom_tpm_type_name(tpm_type));
		return -ENODEV;
	}

	ret = qcom_tpm_qsee_get_version(qtpm, &version);
	if (ret)
		return dev_err_probe(dev, ret, "TPM app version handshake failed\n");

	ret = qcom_tpm_qsee_query_info(qtpm);
	if (ret)
		return dev_err_probe(dev, ret, "failed to query TPM app info\n");

	dev_info(dev, "TPM type %s, app version %#llx, control area %pa\n",
		 qcom_tpm_type_name(tpm_type), version, &qtpm->control_area_phys);

	if (!devm_request_mem_region(dev, qtpm->control_area_phys,
				     QCOM_TPM_QSEE_CONTROL_AREA_SIZE,
				     "qcom-tpm-control-area"))
		return -EBUSY;

	qtpm->control_area = devm_ioremap_wc(dev, qtpm->control_area_phys,
					     QCOM_TPM_QSEE_CONTROL_AREA_SIZE);
	if (!qtpm->control_area)
		return -ENOMEM;

	ret = qcom_tpm_qsee_create_control_area_bridge(qtpm);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to share TPM control area\n");

	/*
	 * tpmm_chip_alloc() makes the chip the aux device's drvdata, which
	 * remove() and tpm_pm_suspend/resume rely on, and drops the chip
	 * reference through devm. Keep private state on chip->dev (as tpm_crb).
	 */
	chip = tpmm_chip_alloc(dev, &qcom_tpm_qsee_ops);
	if (IS_ERR(chip))
		return PTR_ERR(chip);

	qtpm->chip = chip;
	chip->flags |= TPM_CHIP_FLAG_TPM2 | TPM_CHIP_FLAG_SYNC;
	dev_set_drvdata(&chip->dev, qtpm);

	return tpm_chip_register(chip);
}

static void qcom_tpm_qsee_remove(struct auxiliary_device *aux_dev)
{
	struct tpm_chip *chip = auxiliary_get_drvdata(aux_dev);

	tpm_chip_unregister(chip);
}

static DEFINE_SIMPLE_DEV_PM_OPS(qcom_tpm_qsee_pm_ops, tpm_pm_suspend,
				tpm_pm_resume);

static const struct auxiliary_device_id qcom_tpm_qsee_id_table[] = {
	{ .name = "qcom_qseecom.tpm" },
	{}
};
MODULE_DEVICE_TABLE(auxiliary, qcom_tpm_qsee_id_table);

static struct auxiliary_driver qcom_tpm_qsee_driver = {
	.name = "tpm_qcom_qsee",
	.probe = qcom_tpm_qsee_probe,
	.remove = qcom_tpm_qsee_remove,
	.id_table = qcom_tpm_qsee_id_table,
	.driver = {
		.pm = pm_sleep_ptr(&qcom_tpm_qsee_pm_ops),
	},
};
module_auxiliary_driver(qcom_tpm_qsee_driver);

MODULE_DESCRIPTION("Qualcomm QSEE TPM transport driver");
MODULE_LICENSE("GPL");
